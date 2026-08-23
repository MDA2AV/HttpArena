{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

-- HttpArena entry: Warp, the Haskell HTTP server, behind a plain WAI Application.

module Main (main) where

import           Control.Concurrent          (forkIO)
import           Control.Exception           (SomeException, try)
import           Control.Monad               (void, when)
import           Data.Aeson                  (FromJSON (..), (.:))
import qualified Data.Aeson                  as A
import qualified Data.Aeson.Encoding         as E
import qualified Data.ByteString             as B
import qualified Data.ByteString.Builder     as BB
import qualified Data.ByteString.Char8       as BC
import qualified Data.ByteString.Lazy        as BL
import           Data.Char                   (isSpace)
import           Data.List                   (foldl')
import           Data.Maybe                  (fromMaybe)
import           Data.Text                   (Text)
import qualified Data.Text.Read              as TR
import           GHC.Conc                    (getNumProcessors, setNumCapabilities)
import           Network.HTTP.Types          (Query, hContentLength,
                                              hContentType, status200,
                                              status404)
import           Network.Wai
import           Network.Wai.Handler.Warp    (defaultSettings, runSettings,
                                              setPort)
import           Network.Wai.Handler.WarpTLS (runTLS, tlsSettings)
import           Network.Wai.Middleware.Gzip (defaultGzipSettings, gzip)
import           System.Directory            (doesFileExist)
import           System.Environment          (lookupEnv)
import           System.IO                   (hPutStrLn, stderr)

-- ── Dataset ────────────────────────────────────────────────────────────────

data Rating = Rating
  { ratingScore :: !Int
  , ratingCount :: !Int
  }

data Item = Item
  { itemId       :: !Int
  , itemName     :: !Text
  , itemCategory :: !Text
  , itemPrice    :: !Int
  , itemQuantity :: !Int
  , itemActive   :: !Bool
  , itemTags     :: ![Text]
  , itemRating   :: !Rating
  }

instance FromJSON Rating where
  parseJSON = A.withObject "Rating" $ \o ->
    Rating <$> o .: "score" <*> o .: "count"

instance FromJSON Item where
  parseJSON = A.withObject "Item" $ \o ->
    Item <$> o .: "id"
         <*> o .: "name"
         <*> o .: "category"
         <*> o .: "price"
         <*> o .: "quantity"
         <*> o .: "active"
         <*> o .: "tags"
         <*> o .: "rating"

-- A missing or unreadable dataset serves an empty list, it never stops the server.
loadItems :: IO [Item]
loadItems = do
  path <- fromMaybe "/data/dataset.json" <$> lookupEnv "DATASET_PATH"
  raw  <- try (BL.readFile path) :: IO (Either SomeException BL.ByteString)
  return $ case raw of
    Left _   -> []
    Right bs -> fromMaybe [] (A.decode bs)

-- ── JSON encoding ──────────────────────────────────────────────────────────

encodeItem :: Int -> Item -> E.Encoding
encodeItem m it =
  E.pairs $
       E.pair "id"       (E.int  (itemId it))
    <> E.pair "name"     (E.text (itemName it))
    <> E.pair "category" (E.text (itemCategory it))
    <> E.pair "price"    (E.int  (itemPrice it))
    <> E.pair "quantity" (E.int  (itemQuantity it))
    <> E.pair "active"   (E.bool (itemActive it))
    <> E.pair "tags"     (E.list E.text (itemTags it))
    <> E.pair "rating"   (E.pairs $ E.pair "score" (E.int (ratingScore r))
                                 <> E.pair "count" (E.int (ratingCount r)))
    <> E.pair "total"    (E.int  (itemPrice it * itemQuantity it * m))
  where
    r = itemRating it

encodeItems :: [Item] -> Int -> Int -> BL.ByteString
encodeItems items count m =
  E.encodingToLazyByteString $ E.pairs $
       E.pair "items" (E.list (encodeItem m) items)
    <> E.pair "count" (E.int count)

-- ── Request helpers ────────────────────────────────────────────────────────

-- Sum of every query parameter that starts with an integer, non-numeric ones
-- are skipped.
sumQuery :: Query -> Int
sumQuery = foldl' step 0
  where
    step !acc (_, Just v) = case BC.readInt v of
                              Just (n, _) -> acc + n
                              Nothing     -> acc
    step !acc (_, Nothing) = acc

queryInt :: B.ByteString -> Int -> Query -> Int
queryInt key dflt q = case lookup key q of
  Just (Just v) -> case BC.readInt v of
                     Just (n, _) | n /= 0 -> n
                     _                    -> dflt
  _             -> dflt

-- Warp has already undone chunked transfer-encoding here.
bodyInt :: Request -> IO Int
bodyInt req = do
  body <- strictRequestBody req
  let trimmed = BC.dropWhile isSpace (BL.toStrict body)
  return $ case BC.readInt trimmed of
    Just (n, _) -> n
    Nothing     -> 0

-- Streamed, so a 20 MB upload is never held in memory.
countBody :: Request -> IO Int
countBody req = go 0
  where
    go !n = do
      chunk <- getRequestBodyChunk req
      if B.null chunk then return n else go (n + B.length chunk)

parseCount :: Text -> Int
parseCount t = case TR.decimal t of
  Right (n, _) -> n
  Left _       -> 0

-- Warp falls back to chunked framing for a builder with no declared length, so
-- every response here carries its own Content-Length. The gzip middleware drops
-- that header again on the responses it actually compresses.
plain :: B.ByteString -> Response
plain body = responseBuilder status200
  [ (hContentType, "text/plain")
  , (hContentLength, BC.pack (show (B.length body)))
  ] (BB.byteString body)

plainInt :: Int -> Response
plainInt = plain . BC.pack . show

jsonResponse :: BL.ByteString -> Response
jsonResponse body = responseLBS status200
  [ (hContentType, "application/json")
  , (hContentLength, BC.pack (show (BL.length body)))
  ] body

-- ── Application ────────────────────────────────────────────────────────────

app :: [Item] -> Int -> Application
app items total req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["pipeline"]) ->
      respond $ plain "ok"

    ("GET", ["baseline11"]) ->
      respond $ plainInt (sumQuery (queryString req))

    ("POST", ["baseline11"]) -> do
      n <- bodyInt req
      respond $ plainInt (sumQuery (queryString req) + n)

    ("GET", ["json", raw]) -> do
      let asked = parseCount raw
          count = max 0 (min total asked)
          m     = queryInt "m" 1 (queryString req)
      respond $ jsonResponse (encodeItems (take count items) count m)

    ("POST", ["upload"]) -> do
      n <- countBody req
      respond $ plainInt n

    _ -> respond $ responseLBS status404 [(hContentType, "text/plain")] "not found"

-- ── Startup ────────────────────────────────────────────────────────────────

-- The RTS asks the kernel how many cores the host has, which inside a
-- cpu-limited container is the wrong number, so read the cgroup v2 quota first.
getCPUCount :: IO Int
getCPUCount = do
  raw <- try (B.readFile "/sys/fs/cgroup/cpu.max") :: IO (Either SomeException B.ByteString)
  case raw of
    Right s
      | (q:p:_) <- BC.words s
      , q /= "max"
      , Just (quota, _)  <- BC.readInt q
      , Just (period, _) <- BC.readInt p
      , period > 0
      , let n = quota `div` period
      , n >= 1 -> return n
    _ -> getNumProcessors

main :: IO ()
main = do
  caps <- getCPUCount
  setNumCapabilities caps
  items <- loadItems
  let total = length items
  hPutStrLn stderr $ "warp: port 8080, capabilities " ++ show caps
                  ++ ", dataset items " ++ show total
  -- standard mode: compression is the stock wai-extra Gzip middleware with its
  -- defaults, so it only fires when the request negotiates it.
  let handler = gzip defaultGzipSettings (app items total)

  -- json-tls on 8081: the same handler behind warp-tls. The harness only mounts
  -- /certs for the TLS profiles, so without them only 8080 is opened.
  hasCert <- doesFileExist tlsCertPath
  hasKey  <- doesFileExist tlsKeyPath
  when (hasCert && hasKey) $
    void $ forkIO $
      runTLS (tlsSettings tlsCertPath tlsKeyPath)
             (setPort 8081 defaultSettings)
             handler

  runSettings (setPort 8080 defaultSettings) handler

tlsCertPath :: FilePath
tlsCertPath = "/certs/server.crt"

tlsKeyPath :: FilePath
tlsKeyPath = "/certs/server.key"
