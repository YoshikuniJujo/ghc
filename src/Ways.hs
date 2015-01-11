{-# LANGUAGE NoImplicitPrelude #-}
module Ways (
    WayUnit (..),
    Way, tag, 
    
    allWays, defaultWays, 

    vanilla, profiling, logging, parallel, granSim, 
    threaded, threadedProfiling, threadedLogging, 
    debug, debugProfiling, threadedDebug, threadedDebugProfiling,
    dynamic, profilingDynamic, threadedProfilingDynamic,
    threadedDynamic, threadedDebugDynamic, debugDynamic,
    loggingDynamic, threadedLoggingDynamic,

    wayHcArgs, 
    suffix,
    hisuf, osuf, hcsuf,
    detectWay
    ) where

import Base
import Oracles

data WayUnit = Profiling
             | Logging
             | Parallel
             | GranSim
             | Threaded
             | Debug
             | Dynamic
             deriving Eq

data Way = Way
     {
         tag         :: String,    -- e.g., "thr_p"
         units       :: [WayUnit]  -- e.g., [Threaded, Profiling]
     }
     deriving Eq

vanilla   = Way "v"  []
profiling = Way "p"  [Profiling]
logging   = Way "l"  [Logging]
parallel  = Way "mp" [Parallel]
granSim   = Way "gm" [GranSim]

-- RTS only ways. TODO: do we need to define these here?
threaded                 = Way "thr"           [Threaded]
threadedProfiling        = Way "thr_p"         [Threaded, Profiling]
threadedLogging          = Way "thr_l"         [Threaded, Logging]
debug                    = Way "debug"         [Debug]
debugProfiling           = Way "debug_p"       [Debug, Profiling]
threadedDebug            = Way "thr_debug"     [Threaded, Debug]
threadedDebugProfiling   = Way "thr_debug_p"   [Threaded, Debug, Profiling]
dynamic                  = Way "dyn"           [Dynamic]
profilingDynamic         = Way "p_dyn"         [Profiling, Dynamic]
threadedProfilingDynamic = Way "thr_p_dyn"     [Threaded, Profiling, Dynamic]
threadedDynamic          = Way "thr_dyn"       [Threaded, Dynamic]
threadedDebugDynamic     = Way "thr_debug_dyn" [Threaded, Debug, Dynamic]
debugDynamic             = Way "debug_dyn"     [Debug, Dynamic]
loggingDynamic           = Way "l_dyn"         [Logging, Dynamic]
threadedLoggingDynamic   = Way "thr_l_dyn"     [Threaded, Logging, Dynamic]

allWays = [vanilla, profiling, logging, parallel, granSim, 
    threaded, threadedProfiling, threadedLogging, 
    debug, debugProfiling, threadedDebug, threadedDebugProfiling,
    dynamic, profilingDynamic, threadedProfilingDynamic,
    threadedDynamic, threadedDebugDynamic, debugDynamic,
    loggingDynamic, threadedLoggingDynamic]

defaultWays :: Stage -> Action [Way]
defaultWays stage = do
    sharedLibs <- platformSupportsSharedLibs
    return $ [vanilla]
          ++ [profiling | stage /= Stage0] 
          ++ [dynamic   | sharedLibs     ]

-- TODO: do '-ticky' in all debug ways?
wayHcArgs :: Way -> Args
wayHcArgs (Way _ units) =
       (Dynamic `notElem` units) <?> arg "-static"
    <> (Dynamic    `elem` units) <?> arg ["-fPIC", "-dynamic"]
    <> (Threaded   `elem` units) <?> arg "-optc-DTHREADED_RTS"
    <> (Debug      `elem` units) <?> arg "-optc-DDEBUG"
    <> (Profiling  `elem` units) <?> arg "-prof"
    <> (Logging    `elem` units) <?> arg "-eventlog"
    <> (Parallel   `elem` units) <?> arg "-parallel"
    <> (GranSim    `elem` units) <?> arg "-gransim"
    <> (units == [Debug] || units == [Debug, Dynamic]) <?>
       arg ["-ticky", "-DTICKY_TICKY"]

suffix :: Way -> String
suffix way | way == vanilla = ""
           | otherwise      = tag way ++ "_"

hisuf, osuf, hcsuf :: Way -> String
hisuf = (++ "hi") . suffix
osuf  = (++ "o" ) . suffix
hcsuf = (++ "hc") . suffix

-- Detect way from a given extension. Fail if the result is not unique.
detectWay :: FilePath -> Way
detectWay extension = case solutions of
    [way] -> way
    _     -> error $ "Cannot detect way from extension '" ++ extension ++ "'."
  where
    solutions = [w | f <- [hisuf, osuf, hcsuf], w <- allWays, f w == extension]
