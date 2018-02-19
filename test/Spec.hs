import           Control.Exception                        (evaluate)
import           Test.Hspec

import           Control.Concurrent                       (threadDelay)
import           Control.Concurrent.Chan.Unagi.NoBlocking
import           Control.Monad.State.Lazy
import qualified Data.HashMap.Strict                      as H
import           Pipes

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
  describe "timeFilterShow" $ do
    it "prints elements without lumping the IO after the timeout" $ do
      (inch, outch, iq) <- setup
      let msgs = testMsgIndexContent `map` [0..9]
      mapM (writeChan inch . show) msgs
      (_, _) <- runStateT (timeFilterShow 1000 testKey) iq
      True `shouldBe` True

  describe "timeFilterCollect" $ do
    it "returns all the messages just fine" $ do
      (inch, outch, iq) <- setup
      let msgs = testMsgIndexContent `map` [0..9]
      mapM (writeChan inch . show) msgs
      (res, niq) <- timeFilterCollect 1000 testKey iq
      res `shouldBe` msgs

    -- it "gets a single item on a timeout of 1 ms" $ do
    --   (inch, outch, iq) <- setup
    --   _ <- writeChan inch $ show testMsg
    --   x <- take 1 <$> getItemsTimeout iq testKey 1
    --   (snd . head) x `shouldBe` Just testMsg

    -- it "gets 10 items on a timeout of 4000 ms" $ do
    --   (inch, outch, iq) <- setup
    --   let msgs = (\i -> testMsgIndexContent i) `map` [0..9]
    --   mapM (writeChan inch . show) msgs
    --   x <- take 5 <$> getItemsTimeout iq testKey 4000
    --   map snd x `shouldBe` take 5 (map Just msgs)

  -- describe "getItemTimeout" $ do
  --   it "gets a single item on a timeout of 1 ms" $ do
  --     (inch, outch, iq) <- setup
  --     _ <- writeChan inch $ show testMsg
  --     (recvMsg, _) <- runStateT (getItemTimeout testKey 1) iq
  --     recvMsg `shouldBe` (Just testMsg)

  --   it "gets a single item quickly on a timeout of 10000 ms" $ do
  --     (inch, outch, iq) <- setup
  --     _ <- writeChan inch $ show testMsg
  --     (recvMsg, _) <- runStateT (getItemTimeout testKey 10000) iq
  --     recvMsg `shouldBe` (Just testMsg)

  --   it "has no other messages left in state after finishing" $ do
  --     (inch, outch, iq) <- setup
  --     mapM (\i -> writeChan inch $ show $ testMsgIndexContent i) [0..10]
  --     (_, newState) <- runStateT (getItemTimeout testKey 1) iq
  --     let items = (itemsInternal newState)
  --     H.keys items `shouldBe` []

  --   it "times out when no message is sent" $ do
  --     (inch, outch, iq) <- setup
  --     (recvMsg, _) <- runStateT (getItemTimeout testKey 1000) iq
  --     recvMsg `shouldBe` Nothing

  -- describe "getItemBlocking" $ do
  --   it "gets a single item" $ do
  --     (inch, outch, iq) <- setup
  --     _ <- writeChan inch $ show testMsg
  --     (recvMsg, _) <- runStateT (getItemBlocking testKey) iq
  --     recvMsg `shouldBe` testMsg

  --   it "has no other messages left in state after finishing" $ do
  --     (inch, outch, iq) <- setup
  --     _ <- writeChan inch $ show testMsg
  --     (_, newState) <- runStateT (getItemBlocking testKey) iq
  --     let items = (itemsInternal newState)
  --     H.keys items `shouldBe` []

  -- describe "getItemsTimeout" $ do
  --   it "gets a single item on a timeout of 1 ms" $ do
  --     (inch, outch, iq) <- setup
  --     _ <- writeChan inch $ show testMsg
  --     (recvMsg, _) <- runStateT (getItemsTimeout testKey 1000) iq
  --     recvMsg `shouldBe` [testMsg]

  --   it "gets 10 items on a timeout of 10 ms" $ do
  --     (inch, outch, iq) <- setup
  --     let msgs = (\i -> testMsgIndexContent i) `map` [0..10]
  --     mapM (writeChan inch . show) msgs
  --     (recvMsg, _) <- runStateT (getItemsTimeout testKey 10000) iq
  --     recvMsg `shouldBe` msgs

  --   it "has no other messages left in state after finishing" $ do
  --     (inch, outch, iq) <- setup
  --     mapM (\i -> writeChan inch $ show $ testMsgIndexContent i) [0..10]
  --     (_, newState) <- runStateT (getItemBlocking testKey) iq
  --     let items = (itemsInternal newState)
  --     H.keys items `shouldBe` []

  -- describe "addToQueue" $ do
  --   it "is able to add messages to queue which can be fetched" $ do
  --     (_, outch, iq) <- setup
  --     let action = do
  --           addToQueue testMsg
  --           getItemBlocking testKey
  --     (recvMsg, _) <- runStateT action iq
  --     recvMsg `shouldBe` testMsg
