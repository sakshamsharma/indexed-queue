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

timeInMicros :: MonadIO m => m Integer
timeInMicros = liftIO $ (round . (* 1000000)) <$> getPOSIXTime

-- | Helper function to add items to the message queue inside the state.
addToQueue :: (Eq index, Hashable index) => msg ->
              StateT (IndexedQueue rep msg index) IO ()
addToQueue msg = do
  items <- gets itemsInternal
  getIdx <- gets msgToIndex
  modify $ \s -> s { itemsInternal = H.insertWith (++) (getIdx msg) [msg] items }

-- | Producer, which continues to yield units () as long the allowed time
-- is not exceeded. After this, it returns a Nothing.
checkTimeMaybe :: MonadIO m => Integer -> Producer () m (Maybe a)
checkTimeMaybe upto = do
  now <- timeInMicros
  if now > upto then return Nothing
    else do
    yield ()
    checkTimeMaybe upto

-- | Pipe which consumes a Unit (), and yields a Just message from the cache,
-- if there was one there. Otherwise it yields a Nothing.
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

-- | Pipe which consumes a Maybe msg. If there was already a message (in the input)
-- it will yield it. Else, it will try to find a new message from the message queue.
-- It will not block.
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

-- | Pipe which consumes a message, and yields it if it matches the provided
-- index. Else, it will put this message into the cache, and yield nothing.
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

-- | Consumer which runs a provided action on every yield-ed element.
-- This is continued as long as the action returns a Nothing, signifying
-- that the requirement for messages has not yet finished.
-- The moment the action returns a Just, that value is considered the result of
-- this whole computation, and consumer terminates.
consumer :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
            (msg -> m (Maybe a)) ->
            Consumer msg (StateT (IndexedQueue rep msg index) m) (Maybe a)
consumer act = do
  item <- await
  result <- lift $ lift $ act item
  case result of
    Nothing -> consumer act
    _       -> return result

-- | timeFilterShow shows messages from the queue.
-- Filter messages by index, and enforce a time limit.
timeFilterShow :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
                  Integer -> index ->
                  StateT (IndexedQueue rep msg index) m ()
timeFilterShow timeout idx = do
  let act x = do
        liftIO . print $ x
        return Nothing
  _ <- timeFilterAction timeout idx act
  return ()

-- | timeFilterAction executes action on receiving a message in the queue.
-- Filter messages by index, and enforce a time limit.
-- Consider using getItemsBlocking, getItem or processLazyList for simple cases.
timeFilterAction :: (Eq index, Hashable index, Show msg, Read msg, MonadIO m) =>
                    Integer -> index -> (msg -> m (Maybe a)) ->
                    StateT (IndexedQueue rep msg index) m (Maybe a)
timeFilterAction timeout idx action = do
  now <- timeInMicros
  let producer = checkTimeMaybe (now + timeout) >-> checkCache idx >-> (getMsg >-> filterMsg idx)
  runEffect $ producer >-> consumer action

-- | getItemsBlocking fetches items from an IndexedQueue, whose index matches `index`.
-- This call blocks for `timeout` microseconds, where timeout is the first argument.
getItemsBlocking :: (Eq index, Hashable index, Show msg, Read msg) =>
                     Integer -> index ->
                     IndexedQueue rep msg index -> IO ([msg], IndexedQueue rep msg index)
getItemsBlocking timeout idx iq = do
  let act x = do
        prev <- get
        let new = x : prev
        put new
        return Nothing
  ((_, niq), res) <- runStateT (runStateT (timeFilterAction timeout idx act) iq) []
  return (reverse res, niq)

-- | getItem fetches a single item from an IndexedQueue, whose index matches `index`.
-- This call blocks for `timeout` microseconds, where timeout is the first argument.
getItemBlocking timeout idx indexedQueue = do
  let act x = return $ Just x
  ((res, niq), _) <- runStateT (runStateT (timeFilterAction timeout idx act) indexedQueue) ()
  return (res, niq)

-- | processLazyList executes the provided action on all messages of the indexed queue,
-- whose index matches `index`.
-- This call blocks for `timeout` microseconds, where timeout is the first argument.
-- The processing of each message is done as soon as the message arrives.
processLazyList timeout idx indexedQueue action = do
  ((res, niq), _) <- runStateT (runStateT (timeFilterAction timeout idx action) indexedQueue) ()
  return (res, niq)
