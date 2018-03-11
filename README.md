# indexed-queue

# Introduction
Imagine a message queue where you get messages of various types at any point of time. If you wish to run an action on a particular type of messages, for a particular amount of time, you would have to process all types of messages. You cannot discard messages which are not needed right now, so you would have to keep them in memory as well.

This requires:
1. An in-memory cache where you keep messages of different types for future use.
2. Lazy IO (for running IO actions on receipt of certain types of messages).

indexed-queue does this, by providing a wrapper on top of the awesome [pipes](https://hackage.haskell.org/package/pipes) package.

## Example use-case
You are writing a p2p protocol in which the client may receive messages belonging to different rounds. The client is on round `n`, but some other clients may already be on round `n+1`. The local client would not want to discard the messages of the next round, but it still needs messages of round `n`.
