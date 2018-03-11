import           Test.Hspec

import           Control.Concurrent                       hiding (newChan,
                                                           readChan, writeChan)
import           Control.Concurrent.Chan.Unagi.NoBlocking
import           Control.Concurrent.MVar
import           Control.Exception
import           Control.Monad.State.Lazy
import qualified Data.HashMap.Strict                      as H
import           Pipes
import           System.Exit
import           System.Timeout


import           IndexedQueue

data Msg = Msg { contents :: String
               , key      :: String
               } deriving (Show, Read, Eq)

main :: IO ()
main = spec

setup :: IO (InChan String, OutChan String, IndexedQueue String Msg String)
setup = do
  (inch, outch) <- newChan
  let iq = IndexedQueue { channel = outch
                        , bareToMsg = read
                        , msgToIndex = key
                        , itemsInternal = H.empty
                        }
  return (inch, outch, iq)

testContent = "this is ** testing"
testKey     = "weird \\ /// ** key"
testMsg     = Msg { contents = testContent , key = testKey }

testMsgIndexContent i = Msg { contents = show i , key = testKey }

spec :: IO ()
spec = hspec $ do

  describe "timeFilterAction" $ do
    it "Completes the IO actions as elements get available, and not after the timeout" $ do
      (inch, outch, inQueue) <- setup
      let msgs = testMsgIndexContent `map` [0..19]
      mapM (writeChan inch . show) msgs
      myMVar <- newMVar $ testMsgIndexContent (-1)

      let action v = do
            modifyMVar_ myMVar (\_ -> return v)
            return Nothing
      let myT = do
            -- May take up to 5 seconds.
            runStateT (timeFilterAction 5000 testKey action) inQueue
            return ()

      let lateMessageToQueueAction = do
            -- Send a new message after 1 second.
            threadDelay 1000000
            writeChan inch . show $ testMsgIndexContent 20

      -- We kill the processing after 10 ms.
      tid <- forkIOWithUnmask $ \unmask -> unmask myT
      forkIO $ lateMessageToQueueAction
      threadDelay 10000 -- Wait 10ms
      killThread tid

      -- The final message should not have been the one sent after 1 second.
      finalVal <- readMVar myMVar
      (contents finalVal) `shouldBe` "19"


  describe "timeFilterCollect" $ do
    it "returns all the messages lumped together, after the timeout" $ do
      (inch, outch, iq) <- setup
      let msgs = testMsgIndexContent `map` [0..99]
      mapM (writeChan inch . show) msgs
      (res, niq) <- timeFilterCollect 10 testKey iq
      res `shouldBe` msgs
