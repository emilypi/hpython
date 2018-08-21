{-# language DataKinds #-}
{-# language DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# language LambdaCase #-}
{-# language TemplateHaskell #-}
module Language.Python.Internal.Syntax.IR where

import Control.Lens.TH (makeLenses)
import Control.Lens.Traversal (traverseOf)
import Control.Lens.Tuple (_2, _3)
import Control.Lens.Prism (_Right)
import Control.Lens.Review ((#))
import Data.Bifoldable (bifoldMap)
import Data.Bifunctor (bimap)
import Data.Bitraversable (bitraverse)
import Data.List.NonEmpty (NonEmpty)
import Data.Monoid ((<>))
import Data.Validate (Validate(..))

import Language.Python.Internal.Syntax.AugAssign
import Language.Python.Internal.Syntax.BinOp
import Language.Python.Internal.Syntax.CommaSep
import Language.Python.Internal.Syntax.Comment
import Language.Python.Internal.Syntax.Ident
import Language.Python.Internal.Syntax.Import
import Language.Python.Internal.Syntax.ModuleNames
import Language.Python.Internal.Syntax.Numbers
import Language.Python.Internal.Syntax.Strings
import Language.Python.Internal.Syntax.UnOp
import Language.Python.Internal.Syntax.Whitespace
import Language.Python.Validate.Syntax.Error

import qualified Language.Python.Internal.Syntax as Syntax

data Statement a
  = SmallStatements
      (Indents a)
      (SmallStatement a)
      [([Whitespace], SmallStatement a)]
      (Maybe [Whitespace])
      (Either (Maybe Comment) Newline)
  | CompoundStatement
      (CompoundStatement a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CompoundStatement a
  -- ^ 'def' <spaces> <ident> '(' <spaces> stuff ')' <spaces> ':' <spaces> <newline>
  --   <block>
  = Fundef a
      [Decorator a]
      (Indents a)
      (NonEmpty Whitespace) (Ident '[] a)
      [Whitespace] (CommaSep (Param a))
      [Whitespace]
      (Suite a)
  -- ^ 'if' <spaces> <expr> ':' <spaces> <newline>
  --   <block>
  --   [ 'else' <spaces> ':' <spaces> <newline>
  --     <block>
  --   ]
  | If
      (Indents a) a
      [Whitespace] (Expr a) (Suite a)
      [(Indents a, [Whitespace], Expr a, Suite a)]
      (Maybe (Indents a, [Whitespace], Suite a))
  -- ^ 'if' <spaces> <expr> ':' <spaces> <newline>
  --   <block>
  --   ('elif' <spaces> <expr> ':' <spaces> <newline> <block>)*
  --   ['else' <spaces> ':' <spaces> <newline> <block>]
  | While
      (Indents a) a
      [Whitespace] (Expr a) (Suite a)
  -- ^ 'try' <spaces> ':' <spaces> <newline> <block>
  --   ( 'except' <spaces> exceptAs ':' <spaces> <newline> <block> )+
  --   [ 'else' <spaces> ':' <spaces> <newline> <block> ]
  --   [ 'finally' <spaces> ':' <spaces> <newline> <block> ]
  | TryExcept
      (Indents a) a
      [Whitespace] (Suite a)
      (NonEmpty (Indents a, [Whitespace], ExceptAs a, Suite a))
      (Maybe (Indents a, [Whitespace], Suite a))
      (Maybe (Indents a, [Whitespace], Suite a))
  -- ^ 'try' <spaces> ':' <spaces> <newline> <block>
  --   'finally' <spaces> ':' <spaces> <newline> <block>
  | TryFinally
      (Indents a) a
      [Whitespace] (Suite a)
      (Indents a) [Whitespace] (Suite a)
  -- ^ 'for' <spaces> expr 'in' <spaces> expr ':' <spaces> <newline> <block>
  --   [ 'else' <spaces> ':' <spaces> <newline> <block> ]
  | For
      (Indents a) a
      [Whitespace] (Expr a) [Whitespace] (Expr a) (Suite a)
      (Maybe (Indents a, [Whitespace], Suite a))
  -- ^ 'class' <spaces> ident [ '(' <spaces> [ args ] ')' <spaces>] ':' <spaces> <newline>
  --   <block>
  | ClassDef a
      [Decorator a]
      (Indents a)
      (NonEmpty Whitespace) (Ident '[] a)
      (Maybe ([Whitespace], Maybe (CommaSep1' (Arg a)), [Whitespace]))
      (Suite a)
  -- ^ 'with' <spaces> with_item (',' <spaces> with_item)* ':' <spaces> <newline> <block>
  | With
      (Indents a) a
      [Whitespace] (CommaSep1 (WithItem a)) (Suite a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

data SmallStatement a
  = Return a [Whitespace] (Maybe (Expr a))
  | Expr a (Expr a)
  | Assign a (Expr a) (NonEmpty ([Whitespace], Expr a))
  | AugAssign a (Expr a) (AugAssign a) (Expr a)
  | Pass a
  | Break a
  | Continue a
  | Global a (NonEmpty Whitespace) (CommaSep1 (Ident '[] a))
  | Nonlocal a (NonEmpty Whitespace) (CommaSep1 (Ident '[] a))
  | Del a (NonEmpty Whitespace) (CommaSep1' (Expr a))
  | Import
      a
      (NonEmpty Whitespace)
      (CommaSep1 (ImportAs (ModuleName '[]) '[] a))
  | From
      a
      [Whitespace]
      (RelativeModuleName '[] a)
      [Whitespace]
      (ImportTargets '[] a)
  | Raise a
      [Whitespace]
      (Maybe (Expr a, Maybe ([Whitespace], Expr a)))
  | Assert a
      [Whitespace]
      (Expr a)
      (Maybe ([Whitespace], Expr a))
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Param a
  = PositionalParam
  { _paramAnn :: a
  , _paramName :: Ident '[] a
  }
  | KeywordParam
  { _paramAnn :: a
  , _paramName :: Ident '[] a
  -- = spaces
  , _unsafeKeywordParamWhitespaceRight :: [Whitespace]
  , _unsafeKeywordParamExpr :: Expr a
  }
  | StarParam
  { _paramAnn :: a
  -- '*' spaces
  , _unsafeStarParamWhitespace :: [Whitespace]
  , _paramName :: Ident '[] a
  }
  | DoubleStarParam
  { _paramAnn :: a
  -- '**' spaces
  , _unsafeDoubleStarParamWhitespace :: [Whitespace]
  , _paramName :: Ident '[] a
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CompIf a
  -- ^ 'if' <any_spaces> <expr>
  = CompIf a [Whitespace] (Expr a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CompFor a
  -- ^ 'for' <any_spaces> <targets> 'in' <any_spaces> <expr>
  = CompFor a [Whitespace] (Expr a) [Whitespace] (Expr a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Comprehension a
  -- ^ <expr> <comp_for> (comp_for | comp_if)*
  = Comprehension a (Expr a) (CompFor a) [Either (CompFor a) (CompIf a)]
  deriving (Eq, Show)

instance Functor Comprehension where
  fmap f (Comprehension a b c d) =
    Comprehension (f a) (fmap f b) (fmap f c) (fmap (bimap (fmap f) (fmap f)) d)

instance Foldable Comprehension where
  foldMap f (Comprehension a b c d) =
    f a <> foldMap f b <> foldMap f c <> foldMap (bifoldMap (foldMap f) (foldMap f)) d

instance Traversable Comprehension where
  traverse f (Comprehension a b c d) =
    Comprehension <$>
    f a <*>
    traverse f b <*>
    traverse f c <*>
    traverse (bitraverse (traverse f) (traverse f)) d

data Subscript a
  = SubscriptExpr (Expr a)
  | SubscriptSlice
      -- [expr]
      (Maybe (Expr a))
      -- ':' <spaces>
      [Whitespace]
      -- [expr]
      (Maybe (Expr a))
      -- [':' [expr]]
      (Maybe ([Whitespace], Maybe (Expr a)))
  deriving (Eq, Show, Functor, Foldable, Traversable)

data DictItem a
  = DictItem
  { _dictItemAnn :: a
  , _unsafeDictItemKey :: Expr a
  , _unsafeDictItemWhitespace :: [Whitespace]
  , _unsafeDictItemvalue :: Expr a
  }
  | DictUnpack
  { _dictItemAnn :: a
  , _unsafeDictItemUnpackWhitespace :: [Whitespace]
  , _unsafeDictItemUnpackValue :: Expr a
  } deriving (Eq, Show, Functor, Foldable, Traversable)

data Arg a
  = PositionalArg
  { _argAnn :: a
  , _argExpr :: Expr a
  }
  | KeywordArg
  { _argAnn :: a
  , _unsafeKeywordArgName :: Ident '[] a
  , _unsafeKeywordArgWhitespaceRight :: [Whitespace]
  , _argExpr :: Expr a
  }
  | StarArg
  { _argAnn :: a
  , _unsafeStarArgWhitespace :: [Whitespace]
  , _argExpr :: Expr a
  }
  | DoubleStarArg
  { _argAnn :: a
  , _unsafeDoubleStarArgWhitespace :: [Whitespace]
  , _argExpr :: Expr a
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Expr a
  = StarExpr
  { _exprAnnotation :: a
  , _unsafeStarExprWhitespace :: [Whitespace]
  , _unsafeStarExprValue :: Expr a
  }
  | Unit
  { _exprAnnotation :: a
  , _unsafeUnitWhitespaceInner :: [Whitespace]
  , _unsafeUnitWhitespaceRight :: [Whitespace]
  }
  | Lambda
  { _exprAnnotation :: a
  , _unsafeLambdaWhitespace :: [Whitespace]
  , _unsafeLambdaArgs :: CommaSep (Param a)
  , _unsafeLambdaColon :: [Whitespace]
  , _unsafeLambdaBody :: Expr a
  }
  | Yield
  { _exprAnnotation :: a
  , _unsafeYieldWhitespace :: [Whitespace]
  , _unsafeYieldValue :: Maybe (Expr a)
  }
  | YieldFrom
  { _exprAnnotation :: a
  , _unsafeYieldWhitespace :: [Whitespace]
  , _unsafeFromWhitespace :: [Whitespace]
  , _unsafeYieldFromValue :: Expr a
  }
  | Ternary
  { _exprAnnotation :: a
  -- expr
  , _unsafeTernaryValue :: Expr a
  -- 'if' spaces
  , _unsafeTernaryWhitespaceIf :: [Whitespace]
  -- expr
  , _unsafeTernaryCond :: Expr a
  -- 'else' spaces
  , _unsafeTernaryWhitespaceElse :: [Whitespace]
  -- expr
  , _unsafeTernaryElse :: Expr a
  }
  | ListComp
  { _exprAnnotation :: a
  -- [ spaces
  , _unsafeListCompWhitespaceLeft :: [Whitespace]
  -- comprehension
  , _unsafeListCompValue :: Comprehension a
  -- ] spaces
  , _unsafeListCompWhitespaceRight :: [Whitespace]
  }
  | List
  { _exprAnnotation :: a
  -- [ spaces
  , _unsafeListWhitespaceLeft :: [Whitespace]
  -- exprs
  , _unsafeListValues :: Maybe (CommaSep1' (Expr a))
  -- ] spaces
  , _unsafeListWhitespaceRight :: [Whitespace]
  }
  | Dict
  { _exprAnnotation :: a
  , _unsafeDictWhitespaceLeft :: [Whitespace]
  , _unsafeDictValues :: Maybe (CommaSep1' (DictItem a))
  , _unsafeDictWhitespaceRight :: [Whitespace]
  }
  | Set
  { _exprAnnotation :: a
  , _unsafeSetWhitespaceLeft :: [Whitespace]
  , _unsafeSetValues :: CommaSep1' (Expr a)
  , _unsafeSetWhitespaceRight :: [Whitespace]
  }
  | Deref
  { _exprAnnotation :: a
  -- expr
  , _unsafeDerefValueLeft :: Expr a
  -- . spaces
  , _unsafeDerefWhitespaceLeft :: [Whitespace]
  -- ident
  , _unsafeDerefValueRight :: Ident '[] a
  }
  | Subscript
  { _exprAnnotation :: a
  -- expr
  , _unsafeSubscriptValueLeft :: Expr a
  -- [ spaces
  , _unsafeSubscriptWhitespaceLeft :: [Whitespace]
  -- expr
  , _unsafeSubscriptValueRight :: CommaSep1' (Subscript a)
  -- ] spaces
  , _unsafeSubscriptWhitespaceRight :: [Whitespace]
  }
  | Call
  { _exprAnnotation :: a
  -- expr
  , _unsafeCallFunction :: Expr a
  -- ( spaces
  , _unsafeCallWhitespaceLeft :: [Whitespace]
  -- exprs
  , _unsafeCallArguments :: Maybe (CommaSep1' (Arg a))
  -- ) spaces
  , _unsafeCallWhitespaceRight :: [Whitespace]
  }
  | None
  { _exprAnnotation :: a
  , _unsafeNoneWhitespace :: [Whitespace]
  }
  | BinOp
  { _exprAnnotation :: a
  , _unsafeBinOpExprLeft :: Expr a
  , _unsafeBinOpOp :: BinOp a
  , _unsafeBinOpExprRight :: Expr a
  }
  | UnOp
  { _exprAnnotation :: a
  , _unsafeUnOpOp :: UnOp a
  , _unsafeUnOpValue :: Expr a
  }
  | Parens
  { _exprAnnotation :: a
  -- ( spaces
  , _unsafeParensWhitespaceLeft :: [Whitespace]
  -- expr
  , _unsafeParensValue :: Expr a
  -- ) spaces
  , _unsafeParensWhitespaceAfter :: [Whitespace]
  }
  | Ident
  { _exprAnnotation :: a
  , _unsafeIdentValue :: Ident '[] a
  }
  | Int
  { _exprAnnotation :: a
  , _unsafeIntValue :: IntLiteral a
  , _unsafeIntWhitespace :: [Whitespace]
  }
  | Float
  { _exprAnnotation :: a
  , _unsafeFloatValue :: FloatLiteral a
  , _unsafeFloatWhitespace :: [Whitespace]
  }
  | Bool
  { _exprAnnotation :: a
  , _unsafeBoolValue :: Bool
  , _unsafeBoolWhitespace :: [Whitespace]
  }
  | String
  { _exprAnnotation :: a
  , _unsafeStringLiteralValue :: NonEmpty (StringLiteral a)
  }
  | Tuple
  { _exprAnnotation :: a
  -- expr
  , _unsafeTupleHead :: Expr a
  -- , spaces
  , _unsafeTupleWhitespace :: [Whitespace]
  -- [exprs]
  , _unsafeTupleTail :: Maybe (CommaSep1' (Expr a))
  }
  | Not
  { _exprAnnotation :: a
  , _unsafeNotWhitespace :: [Whitespace]
  , _unsafeNotValue :: Expr a
  }
  | Generator
  { _exprAnnotation :: a
  , _generatorValue :: Comprehension a
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Suite a
  -- ':' <space> smallstatement
  = SuiteOne a [Whitespace] (SmallStatement a) Newline
  | SuiteMany a
      -- ':' <spaces> [comment] <newline>
      [Whitespace] Newline
      -- <block>
      (Block a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

newtype Block a
  = Block
  { unBlock
    :: NonEmpty
         (Either
            ([Whitespace], Newline)
            (Statement a))
  } deriving (Eq, Show, Functor, Foldable, Traversable)

data WithItem a
  = WithItem
  { _withItemAnn :: a
  , _withItemValue :: Expr a
  , _withItemBinder :: Maybe ([Whitespace], Expr a)
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Decorator a
  = Decorator
  { _decoratorAnn :: a
  , _decoratorIndents :: Indents a
  , _decoratorWhitespaceLeft :: [Whitespace]
  , _decoratorExpr :: Expr a
  , _decoratorNewline :: Newline
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data ExceptAs a
  = ExceptAs
  { _exceptAsAnn :: a
  , _exceptAsExpr :: Expr a
  , _exceptAsName :: Maybe ([Whitespace], Ident '[] a)
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

newtype Module a
  = Module
  { unModule :: [Either (Indents a, Maybe Comment, Maybe Newline) (Statement a)]
  } deriving (Eq, Show)

data FromIRContext
  = FromIRContext
  { _allowStarred :: Bool
  }

makeLenses ''FromIRContext

fromIR_expr
  :: AsSyntaxError e v a
  => Expr a
  -> Validate [e] (Syntax.Expr '[] a)
fromIR_expr ex =
  case ex of
    StarExpr{} -> Failure [_InvalidUnpacking # _exprAnnotation ex]
    Unit a b c -> pure $ Syntax.Unit a b c
    Lambda a b c d e ->
      (\c' -> Syntax.Lambda a b c' d) <$>
      traverse fromIR_param c <*>
      fromIR_expr e
    Yield a b c -> Syntax.Yield a b <$> traverse fromIR_expr c
    YieldFrom a b c d -> Syntax.YieldFrom a b c <$> fromIR_expr d
    Ternary a b c d e f ->
      (\b' d' -> Syntax.Ternary a b' c d' e) <$>
      fromIR_expr b <*>
      fromIR_expr d <*>
      fromIR_expr f
    ListComp a b c d ->
      (\c' -> Syntax.ListComp a b c' d) <$>
      fromIR_comprehension c
    List a b c d ->
      (\c' -> Syntax.List a b c' d) <$>
      traverseOf (traverse.traverse) fromIR_listItem c
    Dict a b c d ->
      (\c' -> Syntax.Dict a b c' d) <$>
      traverseOf (traverse.traverse) fromIR_dictItem c
    Set a b c d ->
      (\c' -> Syntax.Set a b c' d) <$>
      traverse fromIR_setItem c
    Deref a b c d ->
      (\b' -> Syntax.Deref a b' c d) <$>
      fromIR_expr b
    Subscript a b c d e ->
      (\b' d' -> Syntax.Subscript a b' c d' e) <$>
      fromIR_expr b <*>
      traverse fromIR_subscript d
    Call a b c d e ->
      (\b' d' -> Syntax.Call a b' c d' e) <$>
      fromIR_expr b <*>
      traverseOf (traverse.traverse) fromIR_arg d
    None a b -> pure $ Syntax.None a b
    BinOp a b c d ->
      (\b' d' -> Syntax.BinOp a b' c d') <$>
      fromIR_expr b <*>
      fromIR_expr d
    UnOp a b c ->
      Syntax.UnOp a b <$> fromIR_expr c
    Parens a b c d ->
      (\c' -> Syntax.Parens a b c' d) <$>
      fromIR_expr c
    Ident a b -> pure $ Syntax.Ident a b
    Int a b c -> pure $ Syntax.Int a b c
    Float a b c -> pure $ Syntax.Float a b c
    Bool a b c -> pure $ Syntax.Bool a b c
    String a b -> pure $ Syntax.String a b
    Tuple a b c d ->
      (\b' -> Syntax.Tuple a b' c) <$>
      fromIR_tupleItem b <*>
      traverseOf (traverse.traverse) fromIR_tupleItem d
    Not a b c -> Syntax.Not a b <$> fromIR_expr c
    Generator a b -> Syntax.Generator a <$> fromIR_comprehension b

fromIR_suite
  :: AsSyntaxError e v a
  => Suite a
  -> Validate [e] (Syntax.Suite '[] a)
fromIR_suite s =
  case s of
    SuiteOne a b c d ->
      (\c' -> Syntax.SuiteOne a b c' d) <$>
      fromIR_smallStatement c
    SuiteMany a b c d ->
      Syntax.SuiteMany a b c <$>
      fromIR_block d

fromIR_param
  :: AsSyntaxError e v a
  => Param a
  -> Validate [e] (Syntax.Param '[] a)
fromIR_param p =
  case p of
    PositionalParam a b -> pure $ Syntax.PositionalParam a b
    KeywordParam a b c d -> Syntax.KeywordParam a b c <$> fromIR_expr d
    StarParam a b c -> pure $ Syntax.StarParam a b c
    DoubleStarParam a b c -> pure $ Syntax.DoubleStarParam a b c

fromIR_arg
  :: AsSyntaxError e v a
  => Arg a
  -> Validate [e] (Syntax.Arg '[] a)
fromIR_arg a =
  case a of
    PositionalArg a b -> Syntax.PositionalArg a <$> fromIR_expr b
    KeywordArg a b c d -> Syntax.KeywordArg a b c <$> fromIR_expr d
    StarArg a b c -> Syntax.StarArg a b <$> fromIR_expr c
    DoubleStarArg a b c -> Syntax.DoubleStarArg a b <$> fromIR_expr c

fromIR_decorator
  :: AsSyntaxError e v a
  => Decorator a
  -> Validate [e] (Syntax.Decorator '[] a)
fromIR_decorator (Decorator a b c d e) =
  (\d' -> Syntax.Decorator a b c d' e) <$>
  fromIR_expr d

fromIR_exceptAs
  :: AsSyntaxError e v a
  => ExceptAs a
  -> Validate [e] (Syntax.ExceptAs '[] a)
fromIR_exceptAs (ExceptAs a b c) =
  (\b' -> Syntax.ExceptAs a b' c) <$>
  fromIR_expr b

fromIR_withItem
  :: AsSyntaxError e v a
  => WithItem a
  -> Validate [e] (Syntax.WithItem '[] a)
fromIR_withItem (WithItem a b c) =
  Syntax.WithItem a <$>
  fromIR_expr b <*>
  traverseOf (traverse._2) fromIR_expr c

fromIR_comprehension
  :: AsSyntaxError e v a
  => Comprehension a
  -> Validate [e] (Syntax.Comprehension '[] a)
fromIR_comprehension (Comprehension a b c d) =
  Syntax.Comprehension a <$>
  fromIR_expr b <*>
  fromIR_compFor c <*>
  traverse (bitraverse fromIR_compFor fromIR_compIf) d

fromIR_dictItem
  :: AsSyntaxError e v a
  => DictItem a
  -> Validate [e] (Syntax.DictItem '[] a)
fromIR_dictItem di =
  case di of
    DictItem a b c d ->
      (\b' -> Syntax.DictItem a b' c) <$>
      fromIR_expr b <*>
      fromIR_expr d
    DictUnpack a b c ->
      Syntax.DictUnpack a b <$> fromIR_expr c

fromIR_subscript
  :: AsSyntaxError e v a
  => Subscript a
  -> Validate [e] (Syntax.Subscript '[] a)
fromIR_subscript s =
  case s of
    SubscriptExpr a -> Syntax.SubscriptExpr <$> fromIR_expr a
    SubscriptSlice a b c d ->
      (\a' -> Syntax.SubscriptSlice a' b) <$>
      traverse fromIR_expr a <*>
      traverse fromIR_expr c <*>
      traverseOf (traverse._2.traverse) fromIR_expr d

fromIR_block
  :: AsSyntaxError e v a
  => Block a
  -> Validate [e] (Syntax.Block '[] a)
fromIR_block (Block a) =
  Syntax.Block <$> traverseOf (traverse.traverse) fromIR_statement a

fromIR_compFor
  :: AsSyntaxError e v a
  => CompFor a
  -> Validate [e] (Syntax.CompFor '[] a)
fromIR_compFor (CompFor a b c d e) =
  (\c' -> Syntax.CompFor a b c' d) <$>
  fromIR_expr c <*>
  fromIR_expr e

fromIR_compIf
  :: AsSyntaxError e v a
  => CompIf a
  -> Validate [e] (Syntax.CompIf '[] a)
fromIR_compIf (CompIf a b c) =
  Syntax.CompIf a b <$> fromIR_expr c

fromIR_statement
  :: AsSyntaxError e v a
  => Statement a
  -> Validate [e] (Syntax.Statement '[] a)
fromIR_statement ex =
  case ex of
    SmallStatements a b c d e ->
      (\b' c' -> Syntax.SmallStatements a b' c' d e) <$>
      fromIR_smallStatement b <*>
      traverseOf (traverse._2) fromIR_smallStatement c
    CompoundStatement a ->
      Syntax.CompoundStatement <$> fromIR_compoundStatement a

fromIR_smallStatement
  :: AsSyntaxError e v a
  => SmallStatement a
  -> Validate [e] (Syntax.SmallStatement '[] a)
fromIR_smallStatement ex =
  case ex of
    Assign a b c ->
      Syntax.Assign a <$>
      fromIR_expr b <*>
      traverseOf (traverse._2) fromIR_expr c
    Return a b c -> Syntax.Return a b <$> traverse fromIR_expr c
    Expr a b -> Syntax.Expr a <$> fromIR_expr b
    AugAssign a b c d ->
      (\b' d' -> Syntax.AugAssign a b' c d') <$>
      fromIR_expr b <*>
      fromIR_expr d
    Pass a -> pure $ Syntax.Pass a
    Break a -> pure $ Syntax.Break a
    Continue a -> pure $ Syntax.Continue a
    Global a b c -> pure $ Syntax.Global a b c
    Nonlocal a b c -> pure $ Syntax.Nonlocal a b c
    Del a b c -> Syntax.Del a b <$> traverse fromIR_expr c
    Import a b c -> pure $ Syntax.Import a b c
    From a b c d e -> pure $ Syntax.From a b c d e
    Raise a b c ->
      Syntax.Raise a b <$>
      traverse
        (\(a, b) -> (,) <$>
          fromIR_expr a <*>
          traverseOf (traverse._2) fromIR_expr b)
        c
    Assert a b c d ->
      Syntax.Assert a b <$>
      fromIR_expr c <*>
      traverseOf (traverse._2) fromIR_expr d

fromIR_compoundStatement
  :: AsSyntaxError e v a
  => CompoundStatement a
  -> Validate [e] (Syntax.CompoundStatement '[] a)
fromIR_compoundStatement st =
  case st of
    Fundef a b c d e f g h i ->
      (\b' g' i' -> Syntax.Fundef a b' c d e f g' h i') <$>
      traverse fromIR_decorator b <*>
      traverse fromIR_param g <*>
      fromIR_suite i
    If a b c d e f g ->
      Syntax.If a b c <$>
      fromIR_expr d <*>
      fromIR_suite e <*>
      traverse (\(a, b, c, d) -> (,,,) a b <$> fromIR_expr c <*> fromIR_suite d) f <*>
      traverseOf (traverse._3) fromIR_suite g
    While a b c d e ->
      Syntax.While a b c <$> fromIR_expr d <*> fromIR_suite e
    TryExcept a b c d e f g ->
      Syntax.TryExcept a b c <$>
      fromIR_suite d <*>
      traverse (\(a, b, c, d) -> (,,,) a b <$> fromIR_exceptAs c <*> fromIR_suite d) e <*>
      traverseOf (traverse._3) fromIR_suite f <*>
      traverseOf (traverse._3) fromIR_suite g
    TryFinally a b c d e f g ->
      (\d' -> Syntax.TryFinally a b c d' e f) <$> fromIR_suite d <*> fromIR_suite g
    For a b c d e f g h ->
      (\d' -> Syntax.For a b c d' e) <$>
      fromIR_expr d <*>
      fromIR_expr f <*>
      fromIR_suite g <*>
      traverseOf (traverse._3) fromIR_suite h
    ClassDef a b c d e f g ->
      (\b' -> Syntax.ClassDef a b' c d e) <$>
      traverse fromIR_decorator b <*>
      traverseOf (traverse._2.traverse.traverse) fromIR_arg f <*>
      fromIR_suite g
    With a b c d e ->
      Syntax.With a b c <$>
      traverse fromIR_withItem d <*>
      fromIR_suite e

fromIR_listItem
  :: AsSyntaxError e v a
  => Expr a
  -> Validate [e] (Syntax.ListItem '[] a)
fromIR_listItem (StarExpr a b c) =
  Syntax.ListUnpack a [] b <$> fromIR_expr c
fromIR_listItem (Parens a b c d) =
  (\case
      Syntax.ListUnpack w x y z -> Syntax.ListUnpack w ((b, d) : x) y z
      Syntax.ListItem x y -> Syntax.ListItem a (Syntax.Parens x b y d)) <$>
  fromIR_listItem c
fromIR_listItem e = (\x -> Syntax.ListItem (Syntax._exprAnnotation x) x) <$> fromIR_expr e

fromIR_tupleItem
  :: AsSyntaxError e v a
  => Expr a
  -> Validate [e] (Syntax.TupleItem '[] a)
fromIR_tupleItem (StarExpr a b c) =
  Syntax.TupleUnpack a [] b <$> fromIR_expr c
fromIR_tupleItem (Parens a b c d) =
  (\case
      Syntax.TupleUnpack w x y z -> Syntax.TupleUnpack w ((b, d) : x) y z
      Syntax.TupleItem x y -> Syntax.TupleItem a (Syntax.Parens x b y d)) <$>
  fromIR_tupleItem c
fromIR_tupleItem e =
  (\x -> Syntax.TupleItem (Syntax._exprAnnotation x) x) <$> fromIR_expr e

fromIR_setItem
  :: AsSyntaxError e v a
  => Expr a
  -> Validate [e] (Syntax.SetItem '[] a)
fromIR_setItem (StarExpr a b c) =
  Syntax.SetUnpack a [] b <$> fromIR_expr c
fromIR_setItem (Parens a b c d) =
  (\case
      Syntax.SetUnpack w x y z -> Syntax.SetUnpack w ((b, d) : x) y z
      Syntax.SetItem x y -> Syntax.SetItem a (Syntax.Parens x b y d)) <$>
  fromIR_setItem c
fromIR_setItem e = (\x -> Syntax.SetItem (Syntax._exprAnnotation x) x) <$> fromIR_expr e

fromIR
  :: AsSyntaxError e v a
  => Module a
  -> Validate [e] (Syntax.Module '[] a)
fromIR (Module ms) =
  Syntax.Module <$> traverseOf (traverse._Right) fromIR_statement ms