{-# language OverloadedStrings #-}
{-# language DataKinds #-}
module Roundtrip (roundtripTests) where

import Control.Monad.IO.Class (liftIO)
import Data.String (fromString)
import Data.Text (Text)
import Data.Validate (Validate(..), validate)
import Hedgehog
  ( (===), Group(..), Property, PropertyT, annotateShow, failure, property
  , withTests, withShrinks
  )
import System.FilePath ((</>))

import qualified Data.Text.IO as StrictText
import qualified Data.Text as Strict

import Language.Python.Internal.Lexer (SrcInfo)
import Language.Python.Internal.Render (showModule)
import Language.Python.Parse (parseModule)
import Language.Python.Validate.Indentation
  (Indentation, runValidateIndentation, validateModuleIndentation)
import Language.Python.Validate.Indentation.Error (IndentationError)
import Language.Python.Validate.Syntax
  (runValidateSyntax, validateModuleSyntax, initialSyntaxContext)
import Language.Python.Validate.Syntax.Error (SyntaxError)

roundtripTests :: Group
roundtripTests =
  Group "Roundtrip tests" $
  (\name -> (fromString name, withTests 1 . withShrinks 1 $ doRoundtripFile name)) <$>
  [ "asyncstatements.py"
  , "typeann.py"
  , "dictcomp.py"
  , "imaginary.py"
  , "weird.py"
  , "weird2.py"
  , "django.py"
  , "django2.py"
  , "test.py"
  , "ansible.py"
  , "comments.py"
  , "pypy.py"
  , "pypy2.py"
  , "sqlalchemy.py"
  , "numpy.py"
  , "numpy2.py"
  , "mypy.py"
  , "mypy2.py"
  , "requests.py"
  , "requests2.py"
  , "joblib.py"
  , "joblib2.py"
  , "pandas.py"
  , "pandas2.py"
  ]

doRoundtripFile :: FilePath -> Property
doRoundtripFile name =
  property $ do
    file <- liftIO . StrictText.readFile $ "test/files" </> name
    doRoundtrip file

doRoundtrip :: Text -> PropertyT IO ()
doRoundtrip file = do
    py <- validate (\e -> annotateShow e *> failure) pure $ parseModule "test" file
    case runValidateIndentation $ validateModuleIndentation py of
      Failure errs -> annotateShow (errs :: [IndentationError '[] SrcInfo]) *> failure
      Success res ->
        case runValidateSyntax initialSyntaxContext [] (validateModuleSyntax res) of
          Failure errs' -> do
            annotateShow res
            annotateShow (errs' :: [SyntaxError '[Indentation] SrcInfo]) *> failure
          Success _ -> Strict.lines (showModule py) === Strict.lines file
