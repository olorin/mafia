{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Mafia.Process
  ( -- * Inputs
    File
  , Directory
  , Argument
  , EnvKey
  , EnvValue
  , Process(..)

    -- * Outputs
  , Pass(..)
  , Out(..)
  , Err(..)
  , OutErr(..)
  , ProcessError(..)
  , ExitStatus

    -- * Running Processes
  , ProcessResult(..)
  , call
  , call_
  , callFrom
  , callFrom_
  ) where

import           Control.Concurrent (forkIO)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import           Control.Exception (IOException)
import           Control.Monad.Catch (MonadCatch(..), MonadMask(..), try, handle)
import           Control.Monad.IO.Class (MonadIO(..))

import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import           Mafia.Path (File, Directory)

import           P

import           System.Exit (ExitCode(..))
import           System.IO (IO)
import qualified System.Process as Process

import           X.Control.Monad.Trans.Either (EitherT(..))
import           X.Control.Monad.Trans.Either (firstEitherT, hoistEither)

------------------------------------------------------------------------

type Argument = Text
type EnvKey   = Text
type EnvValue = Text

data Process = Process
  { processCommand     :: File
  , processArguments   :: [Argument]
  , processDirectory   :: Maybe Directory
  , processEnvironment :: Maybe (Map EnvKey EnvValue)
  } deriving (Eq, Ord, Show)

------------------------------------------------------------------------

-- | Pass @stdout@ and @stderr@ through to the console.
data Pass = Pass
  deriving (Eq, Ord, Show)

-- | Capture @stdout@ and pass @stderr@ through to the console.
newtype Out a = Out { unOut :: a }
  deriving (Eq, Ord, Show, Functor)

-- | Capture @stderr@ and pass @stdout@ through to the console.
newtype Err a = Err { unErr :: a }
  deriving (Eq, Ord, Show, Functor)

-- | Capture both @stdout@ and @stderr@.
data OutErr a = OutErr { oeOut :: !a, oeErr :: !a }
  deriving (Eq, Ord, Show, Functor)

------------------------------------------------------------------------

type ExitStatus = Int

data ProcessError
  = ProcessFailure   Process ExitStatus
  | ProcessException Process IOException
  deriving (Eq, Show)

------------------------------------------------------------------------

class ProcessResult a where
  callProcess :: (Functor m, MonadIO m, MonadCatch m)
              => Process -> EitherT ProcessError m a

instance ProcessResult Pass where
  callProcess p = withProcess p $ do
    let cp = fromProcess p

    (Nothing, Nothing, Nothing, pid) <- liftIO (Process.createProcess cp)

    code <- liftIO (Process.waitForProcess pid)
    return (code, Pass)

instance ProcessResult (Out ByteString) where
  callProcess p = withProcess p $ do
    let cp = (fromProcess p) { Process.std_out = Process.CreatePipe }

    (Nothing, Just hOut, Nothing, pid) <- liftIO (Process.createProcess cp)

    out  <- liftIO (B.hGetContents hOut)
    code <- liftIO (Process.waitForProcess pid)

    return (code, Out out)

instance ProcessResult (Err ByteString) where
  callProcess p = withProcess p $ do
    let cp = (fromProcess p) { Process.std_err = Process.CreatePipe }

    (Nothing, Nothing, Just hErr, pid) <- liftIO (Process.createProcess cp)

    err  <- liftIO (B.hGetContents hErr)
    code <- liftIO (Process.waitForProcess pid)

    return (code, Err err)

instance ProcessResult (OutErr ByteString) where
  callProcess p = withProcess p $ do
    let cp = (fromProcess p) { Process.std_out = Process.CreatePipe
                             , Process.std_err = Process.CreatePipe }

    (Nothing, Just hOut, Just hErr, pid) <- liftIO (Process.createProcess cp)

    waitOut <- liftIO (forkWait (B.hGetContents hOut))
    waitErr <- liftIO (forkWait (B.hGetContents hErr))

    let liftEIO = EitherT . liftIO

    out  <- firstEitherT (ProcessException p) (liftEIO waitOut)
    err  <- firstEitherT (ProcessException p) (liftEIO waitErr)
    code <- liftIO (Process.waitForProcess pid)

    return (code, OutErr out err)

instance ProcessResult (Out Text) where
  callProcess p = fmap T.decodeUtf8 <$> callProcess p

instance ProcessResult (Err Text) where
  callProcess p = fmap T.decodeUtf8 <$> callProcess p

instance ProcessResult (OutErr Text) where
  callProcess p = fmap T.decodeUtf8 <$> callProcess p

------------------------------------------------------------------------

-- | Call a process with arguments.
--
call :: (ProcessResult a, Functor m, MonadIO m, MonadCatch m)
     => (ProcessError -> e)
     -> File
     -> [Argument]
     -> EitherT e m a

call up cmd args = firstEitherT up (callProcess process)
  where
    process = Process { processCommand     = cmd
                      , processArguments   = args
                      , processDirectory   = Nothing
                      , processEnvironment = Nothing }

-- | Call a process with arguments, passing the output through to stdout/stderr.
--
call_ :: (Functor m, MonadIO m, MonadCatch m)
      => (ProcessError -> e)
      -> File
      -> [Argument]
      -> EitherT e m ()

call_ up cmd args = do
  Pass <- call up cmd args
  return ()

-- | Call a process with arguments from inside a working directory.
--
callFrom :: (ProcessResult a, Functor m, MonadIO m, MonadCatch m)
         => (ProcessError -> e)
         -> Directory
         -> File
         -> [Argument]
         -> EitherT e m a

callFrom up dir cmd args = firstEitherT up (callProcess process)
  where
    process = Process { processCommand     = cmd
                      , processArguments   = args
                      , processDirectory   = Just dir
                      , processEnvironment = Nothing }

-- | Call a process with arguments from inside a working directory.
--
callFrom_ :: (Functor m, MonadIO m, MonadCatch m)
          => (ProcessError -> e)
          -> Directory
          -> File
          -> [Argument]
          -> EitherT e m ()

callFrom_ up dir cmd args = do
  Pass <- callFrom up dir cmd args
  return ()

------------------------------------------------------------------------

withProcess :: (MonadIO m, MonadCatch m)
            => Process
            -> EitherT ProcessError m (ExitCode, a)
            -> EitherT ProcessError m a

withProcess p io = handle onError $ do
    (code, result) <- io
    case code of
      ExitSuccess   -> return result
      ExitFailure x -> hoistEither (Left (ProcessFailure p x))
  where
    onError (e :: IOException) = hoistEither (Left (ProcessException p e))

fromProcess :: Process -> Process.CreateProcess
fromProcess p = Process.CreateProcess
    { Process.cmdspec       = Process.RawCommand cmd args
    , Process.cwd           = cwd
    , Process.env           = env
    , Process.std_in        = Process.Inherit
    , Process.std_out       = Process.Inherit
    , Process.std_err       = Process.Inherit
    , Process.close_fds     = False
    , Process.create_group  = False
    , Process.delegate_ctlc = False }
  where
    cmd  = T.unpack (processCommand p)
    args = fmap T.unpack (processArguments p)
    cwd  = fmap T.unpack (processDirectory p)

    env  = fmap (fmap (bimap T.unpack T.unpack) . Map.toList)
                (processEnvironment p)

------------------------------------------------------------------------

forkWait :: IO a -> IO (IO (Either IOException a))
forkWait io = do
  mv <- newEmptyMVar

  _  <- mask $ \restore ->
    forkIO $ do
      x <- try (restore io)
      putMVar mv x

  return (takeMVar mv)
