module IndexedQueue where

import           Control.Concurrent.Chan.Unagi.NoBlocking
import           Control.Monad
import           Control.Monad.State.Lazy                 (lift, liftIO)
import           Control.Monad.Trans.State.Lazy
import           Data.Hashable
import qualified Data.HashMap.Strict                      as H
import           Data.Time.Clock.POSIX
import           Pipes


data IndexedQueue rep msg index =
  IndexedQueue { channel       :: OutChan rep
               , bareToMsg     :: rep -> msg
               , msgToIndex    :: msg -> index
               , itemsInternal :: H.HashMap index [msg]
               }

timeInMillis :: MonadIO m => m Integer
timeInMillis = liftIO $ (round . (* 1000)) <$> getPOSIXTime

checkTime :: MonadIO m => Integer -> Producer () m ()
checkTime upto = do
  now <- timeInMillis
  unless (now > upto) $ do
    yield ()
    checkTime upto

checkTimeMaybe :: MonadIO m => Integer -> Producer () m (Maybe a)
checkTimeMaybe upto = do
  now <- timeInMillis
  if now > upto then return Nothing
    else do
    yield ()
    checkTimeMaybe upto

checkCache :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
              index ->
              Pipe () (Maybe msg) (StateT (IndexedQueue rep msg index) m) (Maybe a)
checkCache idx = do
  await
  items <- lift $ gets itemsInternal
  case H.lookup idx items of
    Just (x:xs) -> do
      yield $ Just x
      lift $ modify $ \s -> s { itemsInternal = H.insert idx xs items }
      checkCache idx
    _ -> do
      yield Nothing
      checkCache idx

getMsg :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
          Pipe (Maybe msg) msg (StateT (IndexedQueue rep msg index) m) (Maybe a)
getMsg = do
  fromCache <- await
  case fromCache of
    Just x -> do
      yield x
      getMsg
    Nothing -> do
        ch <- lift $ gets channel
        msg <- liftIO $ tryReadChan ch >>= tryRead
        case msg of
            Nothing -> getMsg
            Just x  -> do
                conv <- lift $ gets bareToMsg
                yield $ conv x
                getMsg

filterMsg :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
             index ->
             Pipe msg msg (StateT (IndexedQueue rep msg index) m) (Maybe a)
filterMsg idx = do
  msg <- await
  getIdx <- lift $ gets msgToIndex
  let nidx = getIdx msg
  if nidx == idx then yield msg
    else do
    items <- lift $ gets itemsInternal
    lift $ modify $ \s -> s { itemsInternal = H.insertWith (++) nidx [msg] items }
  filterMsg idx

consumer :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
            (msg -> m (Maybe a)) ->
            Consumer msg (StateT (IndexedQueue rep msg index) m) (Maybe a)
consumer act = do
  item <- await
  result <- lift $ lift $ act item
  case result of
    Nothing -> consumer act
    _       -> return result

timeFilterShow :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
                  Integer -> index ->
                  StateT (IndexedQueue rep msg index) m ()
timeFilterShow timeout idx = do
  let act x = do
        liftIO . print $ x
        return Nothing
  _ <- timeFilterAction timeout idx act
  return ()

timeFilterCollect :: (Eq index, Hashable index, Show msg, Read msg) =>
                     Integer -> index ->
                     IndexedQueue rep msg index -> IO ([msg], IndexedQueue rep msg index)
timeFilterCollect timeout idx iq = do
  let act x = do
        prev <- get
        let new = x : prev
        put new
        return Nothing
  ((_, niq), res) <- runStateT (runStateT (timeFilterAction timeout idx act) iq) []
  return (reverse res, niq)

-- | Executes action on receiving a message of type index.
timeFilterAction :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
                    Integer -> index -> (msg -> m (Maybe a)) ->
                    StateT (IndexedQueue rep msg index) m (Maybe a)
timeFilterAction timeout idx action = do
  now <- timeInMillis
  let producer = checkTimeMaybe (now + timeout) >-> checkCache idx >-> (getMsg >-> filterMsg idx)
  runEffect $ producer >-> consumer action

addToQueue :: (Eq index, Hashable index) => msg ->
              StateT (IndexedQueue rep msg index) IO ()
addToQueue msg = do
  items <- gets itemsInternal
  getIdx <- gets msgToIndex
  modify $ \s -> s { itemsInternal = H.insertWith (++) (getIdx msg) [msg] items }
