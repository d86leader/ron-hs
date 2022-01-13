{-# OPTIONS_GHC -Wno-missing-signatures -Wno-unused-do-bind #-}
module Data.Ron.Deserialize
    ( loads
    ) where

import Control.Applicative ((<|>), liftA2)
import Data.Char (isAlpha, isAlphaNum, chr)
import Data.Map (Map)
import Data.Text (Text, cons)
import Data.Vector (Vector)

import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.Lazy as Text (toStrict)
import qualified Data.Text.Lazy.Builder as Builder
import qualified Data.Vector as Vector

import Data.Attoparsec.Text hiding (hexadecimal, decimal)
import Data.Ron.Value
import Prelude hiding (takeWhile)


-- Each parser function assumes there is no whitespace before it, and must
-- consume all whitespace after it.
--
-- Parsers don't backtrack at all (except a few characters back sometimes
-- internally). It's mostly possible to understand what value is in front of us
-- by its first character, but sometimes we do have to parse the whole
-- identifier or number to see what character comes after it. The parsers xOrY
-- take care of that.
-- But just using those xOrY is not enough at times, since I didn't figure out
-- how to compose them properly: there are a lot of places where this ambiguity
-- arises. So i just duplicated that code. It's still not that bad, but could
-- be a lot better..
--
-- Also, fucking raw strings. Why not just start them with '#'?


-- | Parse a string to a  'Value'. The error is produced by attoparsec and is
-- not very useful.
loads :: Text -> Either String Value
loads = parseOnly (ws *> toplevel <* endOfInput)


-- | Toplevel is either a toplevel 'list', toplevel 'record', or a regular ron
-- 'value'. The first two are hs-ron extensions
toplevel :: Parser Value
toplevel = peekChar' >>= \case
    -- raw string, algebraic struct, or a field in toplevel 'record'
    'r' -> skip1 >> peekChar >>= \case
        Nothing -> pure $ Unit "r"
        Just '#' -> String <$> ronRawString
        Just '\"' -> String <$> ronRawString
        _ -> do
            ident <- cons 'r' <$> takeWhile isKeyword
            ws
            peekChar >>= \case
                Just '(' -> recordOrTuple ident >>= toplevelList
                Just ':' -> toplevelRecord ident
                _ -> ws *> pure (Unit ident)
    c | startsIdentifier c -> do
            ident <- takeWhile isKeyword
            ws
            peekChar >>= \case
                Just '(' -> recordOrTuple ident >>= toplevelList
                Just ':' -> skip1 *> ws *> toplevelRecord ident
                _ -> ws *> toplevelList (Unit ident)
      | otherwise -> value >>= toplevelList

toplevelList :: Value -> Parser Value
toplevelList first = peekChar >>= \case
    Just ',' -> do
        skip1 -- ,
        ws
        xs <- sepBy value (char ',' *> ws)
        option () $ char ',' *> ws
        pure . List . Vector.fromList $ first:xs
    _ -> pure first

toplevelRecord :: Text -> Parser Value
toplevelRecord firstField = do
    firstValue <- value
    let initial = (firstField, firstValue)
    peekChar >>= \case
        Just ',' -> do
            skip1 -- ,
            ws
            let pair = do
                    k <- liftA2 cons (satisfy startsIdentifier) (takeWhile isKeyword)
                    ws
                    char ':'
                    ws
                    v <- value
                    pure (k, v)
            xs <- sepBy pair (char ',' *> ws)
            option () $ char ',' *> ws
            pure . Record "" . Map.fromList $ initial:xs
        Nothing -> pure . Record "" . Map.fromList $ [initial]
        _ -> fail "Expecting , at toplevel record"

value :: Parser Value
value = peekChar' >>= \case
    c | startsNumber c -> intOrFloat
      | startsChar c -> Char <$> character
      | startsString c -> String <$> ronString
      | startsList c -> List <$> list
      | startsMap c -> Map <$> ronMap
      | startsStruct c -> recordOrTuple ""
      | startsIdentifier c -> identifierLike c
      | otherwise -> fail $ "Unexpected symbol: " <> show c


--- Numbers ---


intOrFloat :: Parser Value
intOrFloat = go <* ws where
  go = do
    !positive <- ((== '+') <$> satisfy (\c -> c == '-' || c == '+'))
             <|> pure True
    let intOrFloatSimple = do
            whole <- takeWhile (\c -> decimalDigit c || c == '_')
            peekChar >>= \case
                Just '.' -> skip1 *> (Floating <$> floating positive whole)
                _ -> ws *> pure (Integral $ buildNumber 10 positive whole)
    peekChar' >>= \case
        '.' -> skip1 *> (Floating <$> floating positive "0")
        '0' -> skip1 >> peekChar >>= \case
            Nothing -> pure $ Integral 0
            Just 'x' -> skip1 *> (Integral <$> hexadecimal positive)
            Just 'o' -> skip1 *> (Integral <$> octal positive)
            Just 'b' -> skip1 *> (Integral <$> binary positive)
            Just '.' -> skip1 *> (Floating <$> floating positive "0")
            Just _ -> intOrFloatSimple
        _ -> intOrFloatSimple

buildNumber :: Integer -> Bool -> Text -> Integer
buildNumber base positive digits = mbNegate . Text.foldl' step 0 $ digits where
    mbNegate = if positive then id else negate
    step !a '_' = a
    step !a !d = a * base + toDigit d
    toDigit = \case
        '0' -> 0
        '1' -> 1
        '2' -> 2
        '3' -> 3
        '4' -> 4
        '5' -> 5
        '6' -> 6
        '7' -> 7
        '8' -> 8
        '9' -> 9
        'a' -> 10
        'b' -> 11
        'c' -> 12
        'd' -> 13
        'e' -> 14
        'f' -> 15
        'A' -> 10
        'B' -> 11
        'C' -> 12
        'D' -> 13
        'E' -> 14
        'F' -> 15
        _ -> error "Not a number"

hexadecimal positive
    = buildNumber 16 positive <$> takeWhile (\c -> c == '_' || hexadecimalDigit c) <* ws
decimal positive
    = buildNumber 10 positive <$> takeWhile (\c -> c == '_' || decimalDigit c) <* ws
octal positive
    = buildNumber 8 positive <$> takeWhile (\c -> c == '_' || octalDigit c) <* ws
binary positive
    = buildNumber 2 positive <$> takeWhile (\c -> c == '_' || binaryDigit c) <* ws

floating :: Bool -> Text -> Parser Double
floating positive !wholeStr = do
    -- dot is already skipped
    !fracStr <- takeWhile (\c -> c == '_' || decimalDigit c)
    let !fracPart = fromInteger $! buildNumber 10 positive fracStr
    let !wholePart = fromInteger $! buildNumber 10 positive wholeStr
    let !shift = fromIntegral $! Text.length fracStr
    !e <- (satisfy (\w -> w == 'e' || w == 'E') *> decimal') <|> pure 0
    let !mantissa = wholePart * 10^shift + fracPart
    let !power = e - shift
    ws
    pure $! mantissa * 10^^power
    where
        decimal' = anyChar >>= \case
            '+' -> decimal True
            '-' -> decimal False
            _ -> fail "Expected + or - (scientific notation power)"


--- Strings ---


character :: Parser Char
character = skip1 >> anyChar >>= \case
  '\\' -> escapedChar <* char '\''
  c -> pure c <* char '\''

escapedChar :: Parser Char
escapedChar = anyChar >>= \case
  '\\' -> pure '\\'
  '\"' -> pure '\"'
  'b' -> pure '\b'
  'f' -> pure '\f'
  'n' -> pure '\n'
  'r' -> pure '\r'
  't' -> pure '\t'
  'u' -> do
      digits <- count 4 $ satisfy hexadecimalDigit
      let code = fromIntegral . buildNumber 16 True . Text.pack $ digits
      pure $ chr code
  _ -> fail "Invalid escape sequence"

ronString :: Parser Text
ronString = skip1 *> (Text.toStrict . Builder.toLazyText <$> go mempty) <* skip1 <* ws
  where
    go :: Builder.Builder -> Parser Builder.Builder
    go !builder = do
        chunk <- takeTill (\c -> c == '\"' || c == '\\')
        let !r = builder <> Builder.fromText chunk
        peekChar' >>= \case
            '\"' -> pure r
            '\\' -> do
              skip1
              c <- escapedChar
              go $ r <> Builder.singleton c
            _ -> error "takeTill took till wrong character (not \" or \\)"

ronRawString :: Parser Text
ronRawString = do
    delimeter <- takeWhile (== '#')
    char '\"'
    let go !builder = do
            chunk <- takeWhile (/= '\"')
            skip1
            let !r = builder <> Builder.fromText chunk
            (string delimeter *> pure r) <|> go (r <> Builder.singleton '\"')
    r <- Text.toStrict . Builder.toLazyText <$> go mempty
    ws
    pure r


--- List, Map ---


list :: Parser (Vector Value)
list = do
    skip1 -- [
    ws
    xs <- sepBy value (char ',' *> ws)
    option () $ char ',' *> ws
    char ']'
    ws
    pure . Vector.fromList $ xs

ronMap :: Parser (Map Value Value)
ronMap = do
    skip1 -- {
    ws
    let pair = do
            k <- value
            char ':'
            ws
            v <- value
            pure (k, v)
    xs <- sepBy pair (char ',' *> ws)
    option () $ char ',' *> ws
    char '}'
    ws
    pure . Map.fromList $ xs


--- Algeraic types


recordOrTuple :: Text -> Parser Value
recordOrTuple name = skip1 >> ws >> peekChar' >>= \case
    -- either a value or an identifier (or end)
    -- identifier overlaps with 'record' field
    ')' -> skip1 *> ws *> pure (Unit name)
    'r' -> skip1 >> peekChar' >>= \case
        c | c == '#' || c == '\"' -> do
            val <- String <$> ronRawString
            ws
            Tuple name <$> tupleAndComma [val]
          | otherwise -> common (Just 'r')
    c | startsIdentifier c -> common Nothing
        -- not starting an identifier means it's not a 'record' field, so a 'tuple'
      | otherwise -> Tuple name <$> tuple []
  where
    common mbHead = do
        ident <- maybe id cons mbHead <$> takeWhile isKeyword
        ws
        peekChar' >>= \case
            ':' -> skip1 *> ws *> do
                v <- value
                Record name <$> recordAndComma [(ident, v)]
            '(' -> do -- a 'tuple' with first element as a 'tuple' or 'record'
                val <- recordOrTuple ident
                Tuple name <$> tupleAndComma [val]
            ',' -> skip1 *> ws *> (Tuple name <$> tuple [Unit ident])
            ')' -> skip1 *> ws *> pure (Tuple name (Vector.fromList [Unit ident]))
            _ -> fail "Expecting expecting ':', ',' or '('"


tuple, tupleAndComma :: [Value] -> Parser (Vector Value)
tuple initial = do
    xs <- sepBy value (char ',' *> ws)
    option () $ char ',' *> ws
    char ')'
    ws
    pure . Vector.fromList $ initial <> xs
tupleAndComma initial = anyChar >>= \case
    ',' -> ws *> tuple initial
    ')' -> ws *> pure (Vector.fromList initial)
    _ -> fail "Expecting ',' or ')' in tuple"

record, recordAndComma :: [(Text, Value)] -> Parser (Map Text Value)
record initial = do
    let pair = do
            k <- liftA2 cons (satisfy startsIdentifier) (takeWhile isKeyword)
            ws
            char ':'
            ws
            v <- value
            pure (k, v)
    xs <- sepBy pair (char ',' *> ws)
    option () $ char ',' *> ws
    char ')'
    ws
    pure . Map.fromList $ initial <> xs
recordAndComma initial = anyChar >>= \case
    ',' -> ws *> record initial
    ')' -> ws *> pure (Map.fromList initial)
    _ -> fail "Expecting ',' or ')' in record"

-- | Algebraic struct (named unit, 'record', 'tuple') or a raw string
identifierLike :: Char -> Parser Value
identifierLike 'r' = skip1 >> peekChar >>= \case
    Nothing -> pure $ Unit "r"
    Just '#' -> String <$> ronRawString
    Just '\"' -> String <$> ronRawString
    _ -> do
        name <- cons 'r' <$> takeWhile isKeyword
        ws
        peekChar >>= \case
            Just '(' -> recordOrTuple name
            _ -> ws *> pure (Unit name)
identifierLike _ = do
    name <- takeWhile isKeyword
    ws
    peekChar >>= \case
        Just '(' -> recordOrTuple name
        _ -> ws *> pure (Unit name)


--- Common ---

-- | Whitespace and comment skipper
ws :: Parser ()
ws = skipWhile isSpace >> peekChar >>= \case
    Nothing -> pure ()
    Just c | c == '/' -> skip1 >> anyChar >>= \case
        '/' -> skipWhile (/= '\n') >> endOr skip1 >> ws
        '*' -> goMultiline
        _ -> fail "Unexpected '/', not followed by a comment starting"
    _ -> pure () -- not a comment
  where
    goMultiline = do
        skipWhile (/= '*')
        endOr skip1
        endOr $ do
            c <- anyChar
            if c == '/'
                then ws -- end of multiline comment, try taking some new whitespace
                else goMultiline

isSpace c = c == ' ' || c == '\n' || c == '\r' || c == '\t'
isKeyword c = isAlphaNum c || c == '_' || c == '\''
startsNumber c = c == '+' || c == '-' || c == '.' || decimalDigit c
startsString c = c == '\"'
startsList c = c == '['
startsMap c = c == '{'
startsStruct c = c == '('
startsIdentifier c = isAlpha c || c == '_' -- this can also be a raw string
startsChar c = c == '\''

binaryDigit c = c == '0' || c == '1'
octalDigit c = binaryDigit c || c == '2' || c == '3' || c == '4'
                             || c == '5' || c == '6' || c == '7'
decimalDigit c = octalDigit c || c == '8' || c == '9'
hexadecimalDigit c = decimalDigit c
                  || c == 'a' || c == 'b' || c == 'c' || c == 'd' || c == 'e' || c == 'f'
                  || c == 'A' || c == 'B' || c == 'C' || c == 'D' || c == 'E' || c == 'F'

skip1 = skip (const True)
endOr parser = atEnd >>= \case {True -> pure (); False -> parser}