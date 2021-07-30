module Main where

import Control.Exception (throwIO)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Maybe (fromJust)
import Data.Scientific (Scientific, fromFloatDigits)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import System.Directory (listDirectory)
import System.FilePath.Posix
import Test.Hspec
import Test.Hspec.Golden
import Text.Parsec (ParseError)
import Text.Parsec.Error (errorMessages)
import Text.RawString.QQ

import qualified Data.Aeson as J
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.UTF8 as BLU
import qualified Data.HashMap.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import qualified Test.QuickCheck as Q
import qualified Test.QuickCheck.Arbitrary.Generic as QAG

import GoBasic.Lexer
import GoBasic.Parser
import GoBasic.Eval

--------------------------------------------------------------------------------

main :: IO ()
main = do
  parseTests <- fetchTestFiles "test/data/parser-tests"
  evalTemplates <- fetchTestFiles "test/data/eval-tests"
  source <- fromJust <$> J.decodeFileStrict "test/data/eval-source.json"
  hspec $ do
    checkLexer
    checkParse parseTests
    checkEval source evalTemplates

--------------------------------------------------------------------------------
-- Lexing tests.

checkLexer :: SpecWith ()
checkLexer = describe "Test Lexer" $
  describe "QuickCheck Lexer Tests" $
  it "lexing serialized tokens yields those tokens" $
    Q.property $ \tokens ->
      let serialized = T.intercalate " " $ fmap serialize tokens
      in (fmap teType <$> lexer) serialized `shouldBe` (tokens :: [Token])

--------------------------------------------------------------------------------
-- Parsing tests.

checkParse :: [FilePath] -> SpecWith ()
checkParse paths = describe "Test Parser" $ do
  describe "Explicit Parser Tests" $
    traverse_ mkGoldenParse paths
  describe "QuickCheck Parser Tests" $
    it "Parser matches Aeson for standard JSON values" $
      Q.property $ \value ->
        let serialized = J.encode @J.Value value
            tokens = lexer $ decodeUtf8 $ BL.toStrict serialized
            viaAeson = fromJust $ J.decode @ValueExt serialized
        in parse tokens `shouldSatisfy` succeeds viaAeson

--------------------------------------------------------------------------------
-- Evaluation tests.

checkEval source templates = describe "Test Eval" $ do
  describe "Explicit Parser Tests" $
    traverse_ (mkGoldenEval source) templates

mkGoldenParse :: FilePath -> Spec
mkGoldenParse path =
  before (TIO.readFile path) $
    it path \file ->
     Golden
       { output = either (Left . show) Right $ parse $ lexer file
       , encodePretty = show
       , writeToFile = \path' val -> BL.writeFile path'  (BLU.fromString $ show val)
       , readFromFile = \path' -> read @(Either String ValueExt) . BLU.toString <$> BL.readFile path'
       , goldenFile = let (path', name) = splitFileName path in path' <> "/golden-files/" <> name <> ".golden"
       , actualFile = Nothing
       , failFirstTime = False
       }

mkGoldenEval :: J.Value -> FilePath -> Spec
mkGoldenEval source path =
  before (TIO.readFile path) $
    it path \file ->
      let result = do
            template <- either (Left . show) Right $ parse $ lexer file
            runEval template source
      in Golden
        { output = result
        , encodePretty = show
        , writeToFile = \path' val -> BL.writeFile path' $ either (BLU.fromString) J.encode val
        , readFromFile = \path' -> maybe (Left "bad read") Right . J.decode <$> BL.readFile path'
        , goldenFile = let (path', name) = splitFileName path in path' <> "/golden-files/" <> name <> ".golden"
        , actualFile = Nothing
        , failFirstTime = False
        }

--------------------------------------------------------------------------------
-- Golden test helpers and orphan instances.

--------------------------------------------------------------------------------
-- QuickCheck helpers and orphan instances.

alphabet :: String
alphabet = ['a'..'z'] ++ ['A'..'Z']

alphaNumerics :: String
alphaNumerics = alphabet ++ "0123456789"

whitespace :: Q.Gen Text
whitespace = do
  i <- Q.chooseInt (1, 10)
  spaces <- replicateM i $ Q.frequency [(10, pure (" " :: Text)), (1, pure "\n")]
  pure $ mconcat spaces

instance Q.Arbitrary Text where
  arbitrary = do
    x <- Q.listOf1 (Q.elements alphabet)
    y <- Q.listOf1 (Q.elements alphaNumerics)
    pure $ T.pack $ x <> y

instance Q.Arbitrary Scientific where
  arbitrary = ((fromRational . toRational) :: Int -> Scientific) <$> Q.arbitrary

instance Q.Arbitrary Token where
  arbitrary = QAG.genericArbitrary

instance Q.Arbitrary J.Value where
  arbitrary = Q.sized sizedArbitraryValue
    where
      sizedArbitraryValue n
        | n <= 0 = Q.oneof [pure J.Null, boolean', number', string']
        | otherwise = Q.resize n' $ Q.oneof [pure J.Null, boolean', number', string', array', object']
        where
          n' = n `div` 2
          boolean' = J.Bool <$> Q.arbitrary
          number' = J.Number <$> Q.arbitrary
          string' = J.String <$> Q.arbitrary
          array' = J.Array . V.fromList <$> Q.arbitrary
          object' = J.Object . M.fromList <$> Q.arbitrary

--------------------------------------------------------------------------------
-- Test helpers.

fetchTestFiles :: FilePath -> IO [FilePath]
fetchTestFiles folder = do
  parseTests <- filter (/= "golden-files") <$> listDirectory folder
  pure $ fmap (folder </>) parseTests

succeeds :: Eq a => a -> Either e a -> Bool
succeeds s (Right s') = s == s'
succeeds _ _ = False

fails :: Either e a -> Bool
fails (Right _) = False
fails _ = True
