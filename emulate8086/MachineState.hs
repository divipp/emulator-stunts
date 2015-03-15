{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
module MachineState where

import Data.Word
import Data.Bits
import Data.Monoid
import Control.Concurrent.MVar
import qualified Data.Set as S
import qualified Data.Vector as V
import qualified Data.IntMap.Strict as IM
import qualified Data.ByteString as BS
import qualified Data.Vector.Storable.Mutable as U
import Control.Monad.State
import Control.Monad.Except
import Control.Lens as Lens
import Sound.ALUT

data Request
    = AskKeyInterrupt Word16
    | AskTimerInterrupt Int
    | PrintFreqTable (MVar ())

type Flags = Word16

type Region = (Int, Int)
type Regions = [Region]
type MemPiece = (Regions, Int)

data Config_ = Config_
    { _verboseLevel     :: Int
    , _showReads        :: Bool
    , _showReads'       :: Bool
    , _showCache        :: Bool
    , _showBuffer       :: U.IOVector Word32
    , _showOffset       :: Int
    , _instPerSec       :: Float  -- Hz
    , _speed            :: Int  -- 0: stop
    , _stepsCounter     :: Int
    , _counter          :: Int -- timer interrupt counter
    , _palette          :: V.Vector Word32
    , _gameexe          :: (Int, BS.ByteString)
    , _invalid          :: S.Set (Word16, Word16)

    , _soundSource      :: Source
    , _frequency        :: Word16   -- speaker frequency
    , _interruptRequest :: MVar [Request]
    , _keyDown          :: Word16
    , _speaker          :: Word8     -- 0x61 port
    }

data Regs = Regs { _ax_,_dx_,_bx_,_cx_, _si_,_di_, _cs_,_ss_,_ds_,_es_, _ip_,_sp_,_bp_ :: Word16 }

type UVec = U.IOVector Word8
type Cache = IM.IntMap CacheEntry

data CacheEntry
    = Compiled !Word16{-cs-} !Word16{-ss-} !Int{-num of instr-} !Regions !(Machine ())
    | BuiltIn !(Machine ())
    | DontCache !Int

data MachineState = MachineState
    { _flags_   :: Flags
    , _regs     :: Regs
    , _heap     :: MemPiece     -- heap layout
    , _heap''   :: UVec

    , _retrace  :: [Word16]
    , _intMask  :: Word8

    , _config   :: Config_
    , _cache    :: Cache
    , _labels   :: IM.IntMap BS.ByteString
    , _files    :: IM.IntMap (FilePath, Int)  -- filepath, position
    , _dta      :: Int

    }

type Machine = StateT MachineState IO
type MachinePart a = Lens' MachineState a


$(makeLenses ''Config_)
$(makeLenses ''Regs)
$(makeLenses ''MachineState)


wordToFlags :: Word16 -> Flags
wordToFlags w = fromIntegral $ (w .&. 0xed3) .|. 0x2

emptyState = do
  heap <- liftIO $ U.new $ 0xb0000
  ivar <- newMVar []
  vec2 <- U.new (320*200) :: IO (U.IOVector Word32)
  return $ MachineState
    { _flags_   = wordToFlags 0xf202
    , _regs     = Regs 0 0 0 0  0 0  0 0 0 0  0 0 0
    , _heap     = undefined
    , _heap''   = heap
    , _cache    = IM.empty
    , _labels   = IM.empty
    , _files    = IM.empty
    , _dta      = 0
    , _retrace  = cycle [1,9,0,8] --     [1,0,0,0,0,0,0,1,1,0,0,0,0,0,0,1,0,0,0,0,0,0]
    , _intMask  = 0xf8
    , _config   = Config_
        { _verboseLevel = 2
        , _showReads    = False
        , _showReads'   = True
        , _showCache    = True
        , _showBuffer   = vec2
        , _showOffset   = 0xa0000
        , _instPerSec   = 50
        , _speed        = 3000
        , _stepsCounter = 0
        , _counter      = 0
        , _speaker      = 0x30 -- ??
        , _palette      = defaultPalette
        , _keyDown      = 0x00
        , _interruptRequest = ivar
        , _soundSource  = undefined
        , _frequency    = 0x0000
        , _gameexe      = undefined
        , _invalid      = mempty
        }
    }

defaultPalette :: V.Vector Word32
defaultPalette = V.fromList $ Prelude.map (`shiftL` 8)
        [ 0x000000, 0x0000a8, 0x00a800, 0x00a8a8, 0xa80000, 0xa800a8, 0xa85400, 0xa8a8a8
        , 0x545454, 0x5454fc, 0x54fc54, 0x54fcfc, 0xfc5454, 0xfc54fc, 0xfcfc54, 0xfcfcfc
        , 0x000000, 0x141414, 0x202020, 0x2c2c2c, 0x383838, 0x444444, 0x505050, 0x606060
        , 0x707070, 0x808080, 0x909090, 0xa0a0a0, 0xb4b4b4, 0xc8c8c8, 0xe0e0e0, 0xfcfcfc
        , 0x0000fc, 0x4000fc, 0x7c00fc, 0xbc00fc, 0xfc00fc, 0xfc00bc, 0xfc007c, 0xfc0040
        , 0xfc0000, 0xfc4000, 0xfc7c00, 0xfcbc00, 0xfcfc00, 0xbcfc00, 0x7cfc00, 0x40fc00
        , 0x00fc00, 0x00fc40, 0x00fc7c, 0x00fcbc, 0x00fcfc, 0x00bcfc, 0x007cfc, 0x0040fc
        , 0x7c7cfc, 0x9c7cfc, 0xbc7cfc, 0xdc7cfc, 0xfc7cfc, 0xfc7cdc, 0xfc7cbc, 0xfc7c9c
        , 0xfc7c7c, 0xfc9c7c, 0xfcbc7c, 0xfcdc7c, 0xfcfc7c, 0xdcfc7c, 0xbcfc7c, 0x9cfc7c
        , 0x7cfc7c, 0x7cfc9c, 0x7cfcbc, 0x7cfcdc, 0x7cfcfc, 0x7cdcfc, 0x7cbcfc, 0x7c9cfc
        , 0xb4b4fc, 0xc4b4fc, 0xd8b4fc, 0xe8b4fc, 0xfcb4fc, 0xfcb4e8, 0xfcb4d8, 0xfcb4c4
        , 0xfcb4b4, 0xfcc4b4, 0xfcd8b4, 0xfce8b4, 0xfcfcb4, 0xe8fcb4, 0xd8fcb4, 0xc4fcb4
        , 0xb4fcb4, 0xb4fcc4, 0xb4fcd8, 0xb4fce8, 0xb4fcfc, 0xb4e8fc, 0xb4d8fc, 0xb4c4fc
        , 0x000070, 0x1c0070, 0x380070, 0x540070, 0x700070, 0x700054, 0x700038, 0x70001c
        , 0x700000, 0x701c00, 0x703800, 0x705400, 0x707000, 0x547000, 0x387000, 0x1c7000
        , 0x007000, 0x00701c, 0x007038, 0x007054, 0x007070, 0x005470, 0x003870, 0x001c70
        , 0x383870, 0x443870, 0x543870, 0x603870, 0x703870, 0x703860, 0x703854, 0x703844
        , 0x703838, 0x704438, 0x705438, 0x706038, 0x707038, 0x607038, 0x547038, 0x447038
        , 0x387038, 0x387044, 0x387054, 0x387060, 0x387070, 0x386070, 0x385470, 0x384470
        , 0x505070, 0x585070, 0x605070, 0x685070, 0x705070, 0x705068, 0x705060, 0x705058
        , 0x705050, 0x705850, 0x706050, 0x706850, 0x707050, 0x687050, 0x607050, 0x587050
        , 0x507050, 0x507058, 0x507060, 0x507068, 0x507070, 0x506870, 0x506070, 0x505870
        , 0x000040, 0x100040, 0x200040, 0x300040, 0x400040, 0x400030, 0x400020, 0x400010
        , 0x400000, 0x401000, 0x402000, 0x403000, 0x404000, 0x304000, 0x204000, 0x104000
        , 0x004000, 0x004010, 0x004020, 0x004030, 0x004040, 0x003040, 0x002040, 0x001040
        , 0x202040, 0x282040, 0x302040, 0x382040, 0x402040, 0x402038, 0x402030, 0x402028
        , 0x402020, 0x402820, 0x403020, 0x403820, 0x404020, 0x384020, 0x304020, 0x284020
        , 0x204020, 0x204028, 0x204030, 0x204038, 0x204040, 0x203840, 0x203040, 0x202840
        , 0x2c2c40, 0x302c40, 0x342c40, 0x3c2c40, 0x402c40, 0x402c3c, 0x402c34, 0x402c30
        , 0x402c2c, 0x40302c, 0x40342c, 0x403c2c, 0x40402c, 0x3c402c, 0x34402c, 0x30402c
        , 0x2c402c, 0x2c4030, 0x2c4034, 0x2c403c, 0x2c4040, 0x2c3c40, 0x2c3440, 0x2c3040
        , 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000
        ]

