{-# language BangPatterns #-}
{-# language TypeApplications #-}
{-# language MultiParamTypeClasses #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language FlexibleContexts #-}
{-# language TypeFamilies #-}
{-# language OverloadedStrings #-}
module Language.Python.Internal.Lexer where

import Control.Applicative ((<**>), (<|>), many, optional)
import Control.Lens.Fold ((^?))
import Control.Lens.Getter ((^.))
import Control.Lens.Iso (from)
import Control.Monad (when, replicateM)
import Control.Monad.Except (throwError)
import Control.Monad.State (StateT, evalStateT, get, modify, put)
import Data.Bifunctor (first)
import Data.Digit.Binary (parseBinary)
import Data.Digit.D0 (parse0)
import Data.Digit.Decimal (parseDecimal, parseDecimalNoZero)
import Data.Digit.HeXaDeCiMaL (parseHeXaDeCiMaL)
import Data.Digit.Octal (parseOctal)
import Data.FingerTree (FingerTree, Measured(..))
import Data.Foldable (asum)
import Data.Functor.Identity (Identity)
import Data.List.NonEmpty (NonEmpty(..), some1)
import Data.Monoid (Sum(..))
import Data.Semigroup ((<>))
import Data.Sequence ((!?), (|>), Seq)
import Data.These (These(..))
import Data.Void (Void)
import Text.Megaparsec
  (MonadParsec, ParseError, parse, unPos)
import Text.Megaparsec.Parsers

import qualified Data.FingerTree as FingerTree
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Sequence as Sequence
import qualified Data.Text as Text
import qualified Text.Megaparsec as Parsec

import Language.Python.Internal.Syntax
import Language.Python.Internal.Token (PyToken(..), pyTokenAnn)

data SrcInfo
  = SrcInfo
  { _srcInfoName :: FilePath
  , _srcInfoLine :: !Int
  , _srcInfoCol :: !Int
  , _srcInfoOffset :: !(Maybe Int)
  }
  deriving (Eq, Show)

initialSrcInfo :: FilePath -> SrcInfo
initialSrcInfo fp =
  SrcInfo
  { _srcInfoName = fp
  , _srcInfoLine = 0
  , _srcInfoCol = 0
  , _srcInfoOffset = Just 0
  }

{-# inline getSrcInfo #-}
getSrcInfo :: MonadParsec e s m => m SrcInfo
getSrcInfo =
  (\(Parsec.SourcePos name l c) -> SrcInfo name (unPos l) (unPos c) . Just) <$>
  Parsec.getPosition <*>
  Parsec.getTokensProcessed

parseNewline :: CharParsing m => m Newline
parseNewline =
  LF Nothing <$ char '\n' <|> char '\r' *>
  (CRLF Nothing <$ char '\n' <|> pure (CR Nothing))

parseCommentNewline :: (CharParsing m, Monad m) => m (SrcInfo -> PyToken SrcInfo)
parseCommentNewline = do
  n <- optional (char '#' *> many (satisfy (`notElem` ['\r', '\n'])))
  case n of
    Nothing -> TkNewline <$> (LF Nothing <$ char '\n' <|> char '\r' *> (CRLF Nothing <$ char '\n' <|> pure (CR Nothing)))
    Just c ->
      fmap
        TkNewline
        (LF (Just $ Comment c) <$ char '\n' <|>
         char '\r' *> (CRLF (Just $ Comment c) <$ char '\n' <|> pure (CR . Just $ Comment c))) <|>
      pure (TkComment c)

stringOrBytesPrefix
  :: CharParsing m
  => m (Either
          (Either RawStringPrefix StringPrefix)
          (Either RawBytesPrefix BytesPrefix))
stringOrBytesPrefix =
  (char 'r' *>
   (Right (Left Prefix_rb) <$ char 'b' <|>
    Right (Left Prefix_rB) <$ char 'B' <|>
    pure (Left $ Left Prefix_r))) <|>
  (char 'R' *>
   (Right (Left Prefix_Rb) <$ char 'b' <|>
    Right (Left Prefix_RB) <$ char 'B' <|>
    pure (Left $ Left Prefix_R))) <|>
  (char 'b' *>
   (Right (Left Prefix_br) <$ char 'r' <|>
    Right (Left Prefix_bR) <$ char 'R' <|>
    pure (Right $ Right Prefix_b))) <|>
  (char 'B' *>
   (Right (Left Prefix_Br) <$ char 'r' <|>
    Right (Left Prefix_BR) <$ char 'R' <|>
    pure (Right $ Right Prefix_B))) <|>
  (Left (Right Prefix_u) <$ char 'u') <|>
  (Left (Right Prefix_U) <$ char 'U')

rawStringChars :: (Monad m, CharParsing m) => m a -> m (RawString String)
rawStringChars mc = do
  str <-
    manyTill
      ((\x y -> [x, y]) <$> char '\\' <*> noneOf "\0" <|>
       pure <$> noneOf "\0")
      mc
  case concat str ^? _RawString of
    Nothing -> unexpected "odd number of backslashes terminating raw string"
    Just str' -> pure str'

stringChar :: CharParsing m => m PyChar
stringChar =
  (char '\\' *>
   (escapeChar <|> unicodeChar <|> octChar <|> hexChar <|> pure (Char_lit '\\'))) <|>
  other
  where
    other = Char_lit <$> anyChar
    escapeChar =
      asum @[]
      [ Char_esc_bslash <$ char '\\'
      , Char_esc_singlequote <$ char '\''
      , Char_esc_doublequote <$ char '"'
      , Char_esc_a <$ char 'a'
      , Char_esc_b <$ char 'b'
      , Char_esc_f <$ char 'f'
      , char 'n' *> (Char_newline <$ text "ewline" <|> pure Char_esc_n)
      , Char_esc_r <$ char 'r'
      , Char_esc_t <$ char 't'
      , Char_esc_v <$ char 'v'
      ]

    unicodeChar =
      char 'U' *>
      ((\[a, b, c, d, e, f, g, h] -> Char_uni32 a b c d e f g h) <$>
       replicateM 8 parseHeXaDeCiMaL)
      <|>
      char 'u' *>
      ((\[a, b, c, d] -> Char_uni16 a b c d) <$>
       replicateM 4 parseHeXaDeCiMaL)

    hexChar = Char_hex <$ char 'x' <*> parseHeXaDeCiMaL <*> parseHeXaDeCiMaL
    octChar = Char_octal <$ char 'o' <*> parseOctal <*> parseOctal

number :: (CharParsing m, Monad m) => m (a -> PyToken a)
number = do
  zero <- optional parse0
  case zero of
    Nothing -> do
      nn <- optional $ (:|) <$> parseDecimalNoZero <*> many parseDecimal
      case nn of
        Just n ->
          (\x j ann ->
             case x of
               Nothing ->
                 maybe (TkInt $ IntLiteralDec ann n) (TkImag . ImagLiteralInt ann n) j
               Just (Right e) ->
                 let
                   f = FloatLiteralWhole ann n e
                 in
                   maybe (TkFloat f) (TkImag . ImagLiteralFloat ann f) j
               Just (Left (Left e)) ->
                 let
                   f = FloatLiteralFull ann n (Just (That e))
                 in
                   maybe (TkFloat f) (TkImag . ImagLiteralFloat ann f) j
               Just (Left (Right (a, b))) ->
                 let
                   f = FloatLiteralFull ann n $
                     case (a, b) of
                       (Nothing, Nothing) -> Nothing
                       (Just x, Nothing) -> Just $ This x
                       (Nothing, Just x) -> Just $ That x
                       (Just x, Just y) -> Just $ These x y
                 in
                   maybe (TkFloat f) (TkImag . ImagLiteralFloat ann f) j) <$>
          optional
            (Left <$ char '.' <*>
             (Left <$> floatExp <|>
              Right <$> ((,) <$> optional (some1 parseDecimal) <*> optional floatExp)) <|>
             Right <$> floatExp) <*>
          optional jJ
        Nothing ->
          (\a b j ann ->
             let
               f = FloatLiteralPoint ann a b
             in
               maybe (TkFloat f) (TkImag . ImagLiteralFloat ann f) j) <$>
          -- try is necessary here to prevent the intercepting of dereference tokens
          try (char '.' *> some1 parseDecimal) <*>
          optional floatExp <*>
          optional jJ
    Just z ->
      (\xX a b -> TkInt (IntLiteralHex b xX a)) <$>
      (True <$ char 'X' <|> False <$ char 'x') <*>
      some1 parseHeXaDeCiMaL
      <|>
      (\bB a b -> TkInt (IntLiteralBin b bB a)) <$>
      (True <$ char 'B' <|> False <$ char 'b') <*>
      some1 parseBinary
      <|>
      (\oO a b -> TkInt (IntLiteralOct b oO a)) <$>
      (True <$ char 'O' <|> False <$ char 'o') <*>
      some1 parseOctal
      <|>
      (\n j a ->
         maybe (TkInt $ IntLiteralDec a (z :| n)) (TkImag . ImagLiteralInt a (z :| n)) j) <$>
      try (many parse0 <* notFollowedBy (char '.' <|> char 'e' <|> char 'E' <|> digit)) <*>
      optional jJ
      <|>
      (\n' a ann ->
         case a of
           Left (Left (b, c, j)) ->
             let
               f = FloatLiteralFull ann (z :| n') $
                 case (b, c) of
                   (Nothing, Nothing) -> Nothing
                   (Just x, Nothing) -> Just $ This x
                   (Nothing, Just x) -> Just $ That x
                   (Just x, Just y) -> Just $ These x y
             in
               maybe (TkFloat f) (TkImag . ImagLiteralFloat ann f) j
           Left (Right (x, j)) ->
             let
               f = FloatLiteralWhole ann (z :| n') x
             in
               maybe (TkFloat f) (TkImag . ImagLiteralFloat ann f) j
           Right j -> TkImag $ ImagLiteralInt ann (z :| n') j) <$>
      many parseDecimal <*>
      (Left <$>
       (Left <$>
        ((,,) <$ char '.' <*>
         optional (some1 parseDecimal) <*>
         optional floatExp <*>
         optional jJ) <|>
        Right <$>
        ((,) <$> floatExp <*> optional jJ)) <|>
      Right <$> jJ)
  where
    jJ = False <$ char 'j' <|> True <$ char 'J'
    floatExp =
      FloatExponent <$>
      (True <$ char 'E' <|> False <$ char 'e') <*>
      optional (Pos <$ char '+' <|> Neg <$ char '-') <*>
      some1 parseDecimal

{-# inline parseToken #-}
parseToken
  :: (Monad m, CharParsing m, MonadParsec e s m)
  => m (PyToken SrcInfo)
parseToken =
  (<**>) getSrcInfo $
  try
    (asum
     [ TkIf <$ text "if"
     , TkElse <$ text "else"
     , TkElif <$ text "elif"
     , TkWhile <$ text "while"
     , TkAssert <$ text "assert"
     , TkDef <$ text "def"
     , TkReturn <$ text "return"
     , TkPass <$ text "pass"
     , TkBreak <$ text "break"
     , TkContinue <$ text "continue"
     , TkTrue <$ text "True"
     , TkFalse <$ text "False"
     , TkNone <$ text "None"
     , TkOr <$ text "or"
     , TkAnd <$ text "and"
     , TkIs <$ text "is"
     , TkNot <$ text "not"
     , TkGlobal <$ text "global"
     , TkDel <$ text "del"
     , TkLambda <$ text "lambda"
     , TkImport <$ text "import"
     , TkFrom <$ text "from"
     , TkAs <$ text "as"
     , TkRaise <$ text "raise"
     , TkTry <$ text "try"
     , TkExcept <$ text "except"
     , TkFinally <$ text "finally"
     , TkClass <$ text "class"
     , TkWith <$ text "with"
     , TkFor <$ text "for"
     , TkIn <$ text "in"
     , TkYield <$ text "yield"
     ] <* notFollowedBy (satisfy isIdentifierChar))

    <|>

    asum
    [ number
    , TkRightArrow <$ text "->"
    , TkEllipsis <$ text "..."
    , TkSpace <$ char ' '
    , TkTab <$ char '\t'
    , TkLeftBracket <$ char '['
    , TkRightBracket <$ char ']'
    , TkLeftParen <$ char '('
    , TkRightParen <$ char ')'
    , TkLeftBrace <$ char '{'
    , TkRightBrace <$ char '}'
    , char '<' *>
      (TkLte <$ char '=' <|>
       char '<' *> (TkShiftLeftEq <$ char '=' <|> pure TkShiftLeft) <|>
       pure TkLt)
    , char '=' *> (TkDoubleEq <$ char '=' <|> pure TkEq)
    , char '>' *>
      (TkGte <$ char '=' <|>
       char '>' *> (TkShiftRightEq <$ char '=' <|> pure TkShiftRight) <|>
       pure TkGt)
    , char '*' *>
      (char '*' *> (TkDoubleStarEq <$ char '=' <|> pure TkDoubleStar) <|>
       TkStarEq <$ char '=' <|>
       pure TkStar)
    , char '/' *>
      (char '/' *> (TkDoubleSlashEq <$ char '=' <|> pure TkDoubleSlash) <|>
       TkSlashEq <$ char '=' <|>
       pure TkSlash)
    , TkBangEq <$ text "!="
    , char '^' *> (TkCaretEq <$ char '=' <|> pure TkCaret)
    , char '|' *> (TkPipeEq <$ char '=' <|> pure TkPipe)
    , char '&' *> (TkAmpersandEq <$ char '=' <|> pure TkAmpersand)
    , char '@' *> (TkAtEq <$ char '=' <|> pure TkAt)
    , char '+' *> (TkPlusEq <$ char '=' <|> pure TkPlus)
    , char '-' *> (TkMinusEq <$ char '=' <|> pure TkMinus)
    , char '%' *> (TkPercentEq <$ char '=' <|> pure TkPercent)
    , TkTilde <$ char '~'
    , TkContinued <$ char '\\' <*> parseNewline
    , TkColon <$ char ':'
    , TkSemicolon <$ char ';'
    , parseCommentNewline
    , TkComma <$ char ','
    , TkDot <$ char '.'
    , do
        sp <- try $ optional stringOrBytesPrefix <* char '"'
        case sp of
          Nothing ->
            TkString Nothing DoubleQuote LongString <$
            text "\"\"" <*>
            manyTill stringChar (text "\"\"\"")
            <|>
            TkString Nothing DoubleQuote ShortString <$> manyTill stringChar (char '"')
          Just (Left (Left prefix)) ->
            TkRawString prefix DoubleQuote LongString <$
            text "\"\"" <*>
            rawStringChars (text "\"\"\"")
            <|>
            TkRawString prefix DoubleQuote ShortString <$> rawStringChars (char '"')
          Just (Left (Right prefix)) ->
            TkString (Just prefix) DoubleQuote LongString <$
            text "\"\"" <*>
            manyTill stringChar (text "\"\"\"")
            <|>
            TkString (Just prefix) DoubleQuote ShortString <$> manyTill stringChar (char '"')
          Just (Right (Left prefix)) ->
            TkRawBytes prefix DoubleQuote LongString <$
            text "\"\"" <*>
            rawStringChars (text "\"\"\"")
            <|>
            TkRawBytes prefix DoubleQuote ShortString <$> rawStringChars (char '"')
          Just (Right (Right prefix)) ->
            TkBytes prefix DoubleQuote LongString <$
            text "\"\"" <*>
            manyTill stringChar (text "\"\"\"")
            <|>
            TkBytes prefix DoubleQuote ShortString <$> manyTill stringChar (char '"')
    , do
        sp <- try $ optional stringOrBytesPrefix <* char '\''
        case sp of
          Nothing ->
            TkString Nothing SingleQuote LongString <$
            text "''" <*>
            manyTill stringChar (text "'''")
            <|>
            TkString Nothing SingleQuote ShortString <$> manyTill stringChar (char '\'')
          Just (Left (Left prefix)) ->
            TkRawString prefix SingleQuote LongString <$
            text "''" <*>
            rawStringChars (text "'''")
            <|>
            TkRawString prefix SingleQuote ShortString <$> rawStringChars (char '\'')
          Just (Left (Right prefix)) ->
            TkString (Just prefix) SingleQuote LongString <$
            text "''" <*>
            manyTill stringChar (text "'''")
            <|>
            TkString (Just prefix) SingleQuote ShortString <$> manyTill stringChar (char '\'')
          Just (Right (Left prefix)) ->
            TkRawBytes prefix SingleQuote LongString <$
            text "''" <*>
            rawStringChars (text "'''")
            <|>
            TkRawBytes prefix SingleQuote ShortString <$> rawStringChars (char '\'')
          Just (Right (Right prefix)) ->
            TkBytes prefix SingleQuote LongString <$
            text "''" <*>
            manyTill stringChar (text "'''")
            <|>
            TkBytes prefix SingleQuote ShortString <$> manyTill stringChar (char '\'')
    , fmap TkIdent $
      (:) <$>
      satisfy isIdentifierStart <*>
      many (satisfy isIdentifierChar)
    ]

{-# noinline tokenize #-}
tokenize :: FilePath -> Text.Text -> Either (ParseError Char Void) [PyToken SrcInfo]
tokenize fp = parse (unParsecT tokens) fp
  where
    tokens :: ParsecT Void Text.Text Identity [PyToken SrcInfo]
    tokens = many parseToken <* Parsec.eof

data LogicalLine a
  = LogicalLine
  { llAnn :: a
  , llSpaces :: Indent
  , llLine :: [PyToken a]
  , llEnd :: Maybe (PyToken a, Newline)
  } deriving (Eq, Show)

spaceToken :: PyToken a -> Maybe Whitespace
spaceToken TkSpace{} = Just Space
spaceToken TkTab{} = Just Tab
spaceToken (TkContinued nl _) = Just $ Continued nl []
spaceToken _ = Nothing

collapseContinue :: [(PyToken a, Whitespace)] -> [([PyToken a], Whitespace)]
collapseContinue [] = []
collapseContinue ((tk@TkSpace{}, Space) : xs) =
  ([tk], Space) : collapseContinue xs
collapseContinue ((tk@TkTab{}, Tab) : xs) =
  ([tk], Tab) : collapseContinue xs
collapseContinue ((tk@TkNewline{}, Newline nl) : xs) =
  ([tk], Newline nl) : collapseContinue xs
collapseContinue ((tk@TkContinued{}, Continued nl ws) : xs) =
  let
    xs' = collapseContinue xs
  in
    [(tk : (xs' >>= fst), Continued nl $ ws <> fmap snd xs')]
collapseContinue _ = error "invalid token/whitespace pair in collapseContinue"

newlineToken :: PyToken a -> Maybe Newline
newlineToken (TkNewline nl _) = Just nl
newlineToken _ = Nothing

spanMaybe :: (a -> Maybe b) -> [a] -> ([b], [a])
spanMaybe f as =
  case as of
    [] -> ([], [])
    x : xs ->
      case f x of
        Nothing -> ([], as)
        Just b -> first (b :) $ spanMaybe f xs

-- | Acts like break, but encodes the "insignificant whitespace" rule for parens, braces
-- and brackets
breakOnNewline :: [PyToken a] -> ([PyToken a], Maybe ((PyToken a, Newline), [PyToken a]))
breakOnNewline = go 0
  where
    go _ [] = ([], Nothing)
    go !careWhen0 (tk : tks) =
      case tk of
        TkLeftParen{} -> first (tk :) $ go (careWhen0 + 1) tks
        TkLeftBracket{} -> first (tk :) $ go (careWhen0 + 1) tks
        TkLeftBrace{} -> first (tk :) $ go (careWhen0 + 1) tks
        TkRightParen{} -> first (tk :) $ go (max 0 $ careWhen0 - 1) tks
        TkRightBracket{} -> first (tk :) $ go (max 0 $ careWhen0 - 1) tks
        TkRightBrace{} -> first (tk :) $ go (max 0 $ careWhen0 - 1) tks
        TkNewline nl _
          | careWhen0 == 0 -> ([], Just ((tk, nl), tks))
          | otherwise -> first (tk :) $ go careWhen0 tks
        _ -> first (tk :) $ go careWhen0 tks

logicalLines :: [PyToken a] -> [LogicalLine a]
logicalLines [] = []
logicalLines tks =
  let
    (spaces, rest) = spanMaybe (\a -> (,) a <$> spaceToken a) tks
    (line, rest') = breakOnNewline rest
  in
    LogicalLine
      (case tks of
         [] -> error "couldn't generate annotation for logical line"
         tk : _ -> pyTokenAnn tk)
      (fmap snd (collapseContinue spaces) ^. from indentWhitespaces)
      line
      (fst <$> rest')
      :
    logicalLines (maybe [] snd rest') 

data IndentedLine a
  = Indent Int a
  | Dedent a
  | IndentedLine (LogicalLine a)
  deriving (Eq, Show)

isBlankToken :: PyToken a -> Bool
isBlankToken TkSpace{} = True
isBlankToken TkTab{} = True
isBlankToken TkComment{} = True
isBlankToken TkNewline{} = True
isBlankToken _ = False

data TabError a
  = TabError a
  | IncorrectDedent a
  deriving (Eq, Show)

indentation :: a -> [LogicalLine a] -> Either (TabError a) [IndentedLine a]
indentation ann lls =
  flip evalStateT (pure (ann, mempty)) $
  (<>) <$> (concat <$> traverse go lls) <*> finalDedents
  where
    finalDedents :: StateT (NonEmpty (a, Indent)) (Either (TabError a)) [IndentedLine a]
    finalDedents = do
      (ann, i) :| is <- get
      case is of
        [] -> pure []
        i' : is' -> do
          put $ i' :| is'
          (Dedent ann :) <$> finalDedents

    dedents :: a -> Int -> StateT (NonEmpty (a, Indent)) (Either (TabError a)) [IndentedLine a]
    dedents ann n = do
      is <- get
      let (popped, remainder) = NonEmpty.span ((> n) . indentLevel . snd) is
      when (n `notElem` fmap (indentLevel . snd) (NonEmpty.toList is)) .
        throwError $ IncorrectDedent ann
      put $ case remainder of
        [] -> error "I don't know whether this can happen"
        x : xs -> x :| xs
      pure $ replicate (length popped) (Dedent ann)

    go :: LogicalLine a -> StateT (NonEmpty (a, Indent)) (Either (TabError a)) [IndentedLine a]
    go ll@(LogicalLine ann spcs line nl)
      | all isBlankToken line = pure [IndentedLine ll]
      | otherwise = do
          (_, i) :| is <- get
          let
            et8 = absoluteIndentLevel 8 spcs
            et1 = absoluteIndentLevel 1 spcs
            et8i = absoluteIndentLevel 8 i
            et1i = absoluteIndentLevel 1 i
          when
            (not (et8 < et8i && et1 < et1i) &&
             not (et8 > et8i && et1 > et1i) &&
             not (et8 == et8i && et1 == et1i))
            (throwError $ TabError ann)
          let
            ilSpcs = indentLevel spcs
            ili = indentLevel i
          case compare ilSpcs ili of
            LT -> (<> [IndentedLine ll]) <$> dedents ann ilSpcs
            EQ -> pure [IndentedLine ll]
            GT -> do
              modify $ NonEmpty.cons (ann, spcs)
              pure [Indent (ilSpcs - ili) ann, IndentedLine ll]

data Line a
  = Line
  { lineAnn :: a
  , lineSpaces :: [Indent]
  , lineLine :: [PyToken a]
  , lineEnd :: Maybe Newline
  } deriving (Eq, Show)

logicalToLine :: FingerTree (Sum Int) (Summed Int) -> LogicalLine a -> Line a
logicalToLine leaps (LogicalLine a b c d) =
  Line a (if all isBlankToken c then [b] else splitIndents leaps b) c (snd <$> d)

newtype Nested a
  = Nested
  { unNested :: Seq (Either (Nested a) (Line a))
  } deriving (Eq, Show)

nestedAnn :: Nested a -> Maybe a
nestedAnn (Nested s) = s !? 0 >>= either nestedAnn (pure . lineAnn)

data IndentationError a
  = UnexpectedDedent a
  | ExpectedDedent a
  deriving (Eq, Show)

newtype Summed a
  = Summed
  { getSummed :: a }
  deriving (Eq, Show, Ord, Num)

instance Num a => Measured (Sum a) (Summed a) where
  measure (Summed a) = Sum a

-- | Given a list of indentation jumps (first to last) and some whitespace,
-- divide the whitespace up into "blocks" which correspond to each jump
splitIndents :: FingerTree (Sum Int) (Summed Int) -> Indent -> [Indent]
splitIndents ns ws = go ns ws []
  where
    go :: FingerTree (Sum Int) (Summed Int) -> Indent -> [Indent] -> [Indent]
    go ns ws =
      case FingerTree.viewr ns of
        FingerTree.EmptyR -> (ws :)
        ns' FingerTree.:> n
          | FingerTree.null ns' -> (ws :)
          | otherwise ->
              let
                (befores, afters) =
                  FingerTree.split ((> getSum (measure ns')) . getIndentLevel) $ unIndent ws
              in
                if FingerTree.null afters
                then error $ "could not carve out " <> show n <> " from " <> show ws
                else go ns' (MkIndent befores) .  (MkIndent afters :)

nested :: [IndentedLine a] -> Either (IndentationError a) (Nested a)
nested = fmap Nested . go FingerTree.empty []
  where
    go
      :: FingerTree (Sum Int) (Summed Int)
      -> [(a, Seq (Either (Nested a) (Line a)))]
      -> [IndentedLine a]
      -> Either
           (IndentationError a)
           (Seq (Either (Nested a) (Line a)))
    go leaps [] [] = pure mempty
    go leaps ((ann, a) : as) [] = foldr (\_ _ -> Left $ ExpectedDedent ann) (pure a) as
    go leaps ctxt (Indent n a : is) = go (leaps FingerTree.|> Summed n) ((a, mempty) : ctxt) is
    go leaps [] (Dedent a : is) = Left $ UnexpectedDedent a
    go leaps ((ann, a) : as) (Dedent _ : is) =
      case FingerTree.viewr leaps of
        FingerTree.EmptyR -> error "impossible"
        leaps' FingerTree.:> _ ->
          case as of
            (ann', x) : xs -> go leaps' ((ann', x |> Left (Nested a)) : xs) is
            [] -> go leaps' [(ann, Sequence.singleton $ Left (Nested a))] is
    go leaps [] (IndentedLine ll : is) = go leaps [(llAnn ll, Sequence.singleton (Right $ logicalToLine leaps ll))] is
    go leaps ((ann, a) : as) (IndentedLine ll : is) = go leaps ((ann, a |> Right (logicalToLine leaps ll)) : as) is
