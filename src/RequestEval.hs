{-# LANGUAGE CPP, ViewPatterns #-}

module RequestEval (evaluator) where

import qualified Data.Set as Set
import qualified EvalCxx
import qualified Editing.Parse
import qualified Editing.Diff
import qualified Editing.Execute
import qualified Editing.Basics
import qualified Editing.EditsPreparation
import qualified Parsers as P
import qualified Cxx.Parse
import qualified Cxx.Operations
import qualified Cxx.Show
import qualified Data.List as List
import qualified Data.Stream.NonEmpty as NeList

import Control.Monad.Error (throwError)
import Control.Monad (join)
import Control.Arrow (first, second)
import Cxx.Show (Highlighter)
import Data.Char (isPrint, isSpace)
import Data.Either (partitionEithers)
import Data.Foldable (toList)
import Data.Stream.NonEmpty (NonEmpty((:|)), nonEmpty)
import Data.Set (Set)
import Editing.Basics (FinalCommand(..))
import Parsers ((<|>), eof, option, spaces, getInput, kwd, kwds, Parser, run_parser, ParseResult(..), optional, parseOrFail, commit)
import Util ((.), (‥), (<<), (.∨.), commas_and, capitalize, length_ge, replace, show_long_opt, strip, convert, maybeLast, orElse, E, NeList)
import Request (Context(..), EvalOpt(..), Response(..), HistoryModification(..), EditableRequest(..), EditableRequestKind(..), EphemeralOpt(..), HistoricalRequest, Edit(..), DualARange(..), Range(..))
import Data.SetOps
import Prelude hiding (catch, (.))
import Prelude.Unicode hiding ((∈), (∉))

#include "Util.h"

show_EditableRequest :: Highlighter → EditableRequest → String
show_EditableRequest h (EditableRequest (Evaluate f) s) | Set.null f = Cxx.Parse.highlight h s
show_EditableRequest _ (EditableRequest k s) = show k ++ (if null s then "" else ' ' : s)

instance Show EditableRequest where
  show = show_EditableRequest Cxx.Show.noHighlighting

no_break_space :: Char
no_break_space = '\x00A0'

diff :: EditableRequest → EditableRequest → String
diff (EditableRequest MakeType y) (EditableRequest MakeType x) = pretty $ show . Editing.Diff.diff x y
diff (EditableRequest Precedence y) (EditableRequest Precedence x) = pretty $ show . Editing.Diff.diff x y
diff (EditableRequest (Evaluate flags) y) (EditableRequest (Evaluate flags') x) =
  pretty $ f "removed" flags' flags ++ f "added" flags flags' ++ show . Editing.Diff.diff x y
    where f n fl fl' = maybe [] (\l → [n ++ " " ++ concat (List.intersperse " and " $ map show_long_opt $ toList l)]) (nonEmpty $ Set.elems $ (Set.\\) fl fl')
diff _ _ = "Requests differ in kind."

pretty :: [String] → String -- Todo: This is awkward.
pretty [] = "Requests are identical."
pretty l = capitalize (commas_and l) ++ "."

ellipsis_options :: [(String, Bool)] → NeList [String]
ellipsis_options [] = return []
ellipsis_options ((y, _) : ys) = work ((y, False) : ys)
  where
    dummy = " → ..."
    work [] = return []
    work [(x, _)] = return [x]
    work ((x, False) : xs) = fmap (x:) (work xs)
    work ((x, True) : xs) = work xs >>= \o → if dummy ∈ o
        then (return $ if head o == dummy then o else dummy : o)
        else (dummy : o) :| [x : o]

nicer_namedPathTo :: [String] → String
nicer_namedPathTo l = drop 3 $ concat $ maybeLast (takeWhile ((≤ 140) . length . concat) $ toList n) `orElse` NeList.head n
  where n = ellipsis_options $ map (\s → (" → " ++ s, "expr" `List.isSuffixOf` s)) l
    -- Todo: Also don't abbreviate when there's enough space.

-- The following aliases for 'return' and 'id' serve only to make subsequent monad-heavy code more readable.

pureIO :: a → IO a
pureIO = return

parseSuccess :: a → Parser t a
parseSuccess = return

noErrors :: a → E a
noErrors = return

inIO :: IO a → IO a
inIO = id

inE :: E a → E a
inE = id

continueParsing :: Parser t a → Parser t a
continueParsing = id

propagateE :: Monad m ⇒ E a → (a → m (E b)) → m (E b)
propagateE (Left e) _ = return $ Left e
propagateE (Right x) f = f x

optParser :: Parser Char (E (Set EvalOpt, [EphemeralOpt]))
optParser = first Set.fromList ‥ partitionEithers ‥ option (return []) P.optParser

type CxxEvaluator = EvalCxx.Request → IO (String, Maybe EvalCxx.Fix)

fix_as_edit :: ((Int, Int) → Int) → (EvalCxx.Fix → Edit)
fix_as_edit f (EvalCxx.Fix begin end repl) =
  RangeReplaceEdit (Range begin' $ f end - begin') repl
 where begin' = f begin

linecol_as_offset :: String → (Int, Int) → Int
linecol_as_offset s (line, column) =
  sum (map ((+1) . length) $ take (line - 1) $ lines s) + column - 1

respond :: CxxEvaluator → EditableRequest → E (IO (String, Maybe Edit))
respond evf = case_of
  EditableRequest MakeType d → pureIO . flip (,) Nothing . Cxx.Show.show_simple . Cxx.Parse.makeType d
  EditableRequest Precedence t → pureIO . flip (,) Nothing . Cxx.Parse.precedence t
  EditableRequest (Evaluate opts) code → do
    sc ← parseOrFail (Cxx.Parse.code << eof) (dropWhile isSpace code) "request"
    let 
      short = Cxx.Operations.shortcut_syntaxes $ Cxx.Operations.line_breaks sc
      extra = ["using namespace std;" | NoUsingStd ∉ opts]
        ++ [ "#include \"terse.hpp\"" | Terse ∈ opts]
      expanded_code = show (Cxx.Operations.expand short)
      translate_source_loc :: (Int, Int) → Int
      translate_source_loc =
        Cxx.Operations.unexpand short . linecol_as_offset expanded_code . first (subtract (length extra))
    return $ (second (fix_as_edit translate_source_loc .) .) $ evf $ EvalCxx.Request
      (unlines extra ++ expanded_code)
      (CompileOnly ∉ opts) (NoWarn ∈ opts)

respond_and_remember :: CxxEvaluator → EditableRequest → IO Response
respond_and_remember evf er = do
  (ou, edit) ← either (\x → return ("error: " ++ x, Nothing)) id (respond evf er)
  return $ Response (Just $ AddLast (er, edit)) ou

final_cmd :: Highlighter → FinalCommand → [EditableRequest] → E String
final_cmd h = go where
  go _ [] = throwError "There is no previous request."
  go (Show Nothing) (er:_) = return $ show_EditableRequest h er
  go (Show (Just substrs)) (EditableRequest (Evaluate _) c : _) = do
    l ← (\(Editing.EditsPreparation.Found _ x) → x) ‥ toList . Editing.EditsPreparation.findInStr c (flip (,) return . Cxx.Parse.parseRequest c) substrs
    return $ commas_and (map (\x → '`' : strip (Editing.Basics.selectRange (convert $ replace_range x) c) ++ "`") l) ++ "."
  go (Show (Just _)) (_:_) = throwError "Last (editable) request was not an evaluation request."
  go (Identify substrs) (EditableRequest (Evaluate _) c : _) = do
    tree ← Cxx.Parse.parseRequest c
    l ← (\(Editing.EditsPreparation.Found _ x) → x) ‥ toList . Editing.EditsPreparation.findInStr c (Right (tree, return)) substrs
    return $ concat $ List.intersperse ", " $ map (nicer_namedPathTo . Cxx.Operations.namedPathTo tree . convert . replace_range) l
  go Parse (EditableRequest (Evaluate _) c : _) =
    Cxx.Parse.parseRequest c >> return "Looks fine to me."
  go Diff (x : y : _) = return $ diff x y
  go Diff [_] = throwError "History exhausted."
  go _ (_:_) = throwError "Last (editable) request was not an evaluation request."

editcmd :: Highlighter → CxxEvaluator → [EditableRequest] → [Editing.Basics.Command] → Parser Char (E (EditableRequest, IO (String, Maybe Edit)))
editcmd h evf prevs extra_cmds = do
  oe ← Editing.Parse.commandsP; commit $ (eof >>) $ parseSuccess $ do
  case prevs of
    [] → throwError "There is no prior request."
    prev : _ → do
      (cs, mfcmd) ← oe
      edited ← Editing.Execute.execute (extra_cmds ++ cs) prev
      if length_ge 1000 (editable_body edited) then throwError "Request would become too large." else do
      (,) edited . case mfcmd of
        Just fcmd → return . flip (,) Nothing . final_cmd h fcmd (edited : prevs)
        Nothing → noErrors $ case respond evf edited of
          Left e → return ("error: " ++ e, Nothing)
          Right x → x

cout_response :: CxxEvaluator → String → IO Response
cout_response evf s = Response Nothing .
  fst . evf (EvalCxx.Request ("int main() { std::cout << " ++ s ++ "; }") True False)

p :: Highlighter → CxxEvaluator → EvalCxx.CompileConfig → [HistoricalRequest] → Parser Char (E (IO Response))
p h evf compile_cfg prevs = (spaces >>) $ do
    fcmd_or_error ← Editing.Parse.finalCommandP; commit $ (eof >>) $ return $ do
    fcmd ← fcmd_or_error
    return . Response Nothing . final_cmd h fcmd (map fst prevs)
  <|> do
    kwds ["undo", "revert"]; commit $ case prevs of
      _ : old → kwd "and" >> (do
          fcmd_or_error ← Editing.Parse.finalCommandP; commit $ (eof >>) $ return $ do
          fcmd ← fcmd_or_error
          return . Response (Just DropLast) . final_cmd h fcmd (map fst old)
        <|> do
          y ← editcmd h evf (map fst old) []; return $ do
          (edited, output) ← y
          return $ Response (Just $ ReplaceLast (edited, Nothing)) . fst . output)
      _ → parseSuccess $ throwError "History exhausted."
  <|> do
    kwd "fix"; commit $ case prevs of
        [] → parseSuccess $ throwError "History exhausted."
        (er, Just edit) : old →
            (eof >> parseSuccess (respond_and_remember evf . Editing.Execute.execute [Editing.Basics.FixIt edit] er))
            <|> (kwd "and" >> (do
              fcmd_or_error ← Editing.Parse.finalCommandP; commit $ (eof >>) $ parseSuccess $ do
              edited ← Editing.Execute.execute [Editing.Basics.FixIt edit] er
              fcmd ← fcmd_or_error
              return . Response (Just $ AddLast (edited, Nothing)) . final_cmd h fcmd (edited : map fst old)
            <|> do
              y ← editcmd h evf (er : map fst old) [Editing.Basics.FixIt edit]; return $ do
              (edited, output) ← y
              return $ Response (Just $ AddLast (edited, Nothing)) . fst . output))
        _ → parseSuccess $ throwError "No fix available."
  <|> do
    kwds ["--precedence", "precedence"]
    parseSuccess . noErrors . respond_and_remember evf . EditableRequest Precedence =<< getInput
  <|> do
    kwds ["--make-type", "make type"]
    parseSuccess . noErrors . respond_and_remember evf . EditableRequest MakeType =<< getInput
  <|> do kwds ["help"]; return $ return help_response
  <|> do kwds ["version"]; return $ return version_response
  <|> do kwds ["uname"]; return $ return uname_response
  <|> do
    kwd "--show-compile-flags"
    parseSuccess $ noErrors $ pureIO $ Response Nothing $ unwords $ EvalCxx.compileFlags compile_cfg
  <|> do
    optional (kwd "try"); kwd "again"; commit $ (eof >>) $ return $ case prevs of
      [] → throwError "There is no repeatable request."
      x : _ → Response Nothing ‥ fst ‥ respond evf (fst x)
  <|> do
    y ← editcmd h evf (map fst prevs) []
    parseSuccess $ inE $ (\(edited, output) → do
      (v, w) ← output
      return $ Response (Just $ AddLast (edited, w)) v) . y
  <|> do
    mopts ← optParser; spaces
    propagateE mopts $ \(evalopts, eph_opts) → continueParsing $ do
    case () of { ()
      | Help ∈ eph_opts → parseSuccess $ noErrors help_response
      | Version ∈ eph_opts → parseSuccess $ noErrors version_response
      | Resume ∈ eph_opts → flip fmap (Cxx.Parse.code << eof) $ \code → case prevs of
        [] → throwError "There is no previous resumable request."
        (EditableRequest (Evaluate oldopts) oldcodeblob, _) : _ → do
          case run_parser (Cxx.Parse.code << eof) (dropWhile isSpace oldcodeblob) of
            ParseSuccess oldcode _ _ _ → noErrors $ respond_and_remember evf $
              EditableRequest (Evaluate $ evalopts ∪ oldopts) $ show $ Cxx.Operations.blob $ Cxx.Operations.resume (Cxx.Operations.shortcut_syntaxes oldcode) (Cxx.Operations.shortcut_syntaxes code)
            ParseFailure _ _ _ → throwError "Previous request too malformed to resume."
        _ → throwError "Last (editable) request was not resumable."
      | otherwise → parseSuccess . noErrors . respond_and_remember evf =<< EditableRequest (Evaluate evalopts) . getInput }
  where
    help_response = cout_response evf "help"
    version_response = cout_response evf "\"Clang \" << __clang_version__"
    uname_response = cout_response evf "geordi::uname()"

flatten_evaluation_result :: EvalCxx.EvaluationResult → (String, Maybe EvalCxx.Fix)
flatten_evaluation_result er@(EvalCxx.EvaluationResult _ _ m) = (filter (isPrint .∨. (== '\n')) $ show er, m)

evaluator :: Highlighter → IO (String → Context → IO Response)
evaluator h = do
  (ev, compile_cfg) ← EvalCxx.evaluator
  return $ \r (Context prevs) → do
  either (return . Response Nothing . ("error: " ++)) id $
    join (parseOrFail (p h (flatten_evaluation_result ‥ ev) compile_cfg prevs) (replace no_break_space ' ' r) "request")
