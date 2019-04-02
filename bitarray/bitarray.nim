import memfiles
from os import nil
from strutils import `%`, formatFloat, ffDecimal, toBin
from random import rand, randomize
from times import nil


# Type declarations
type
  BitArrayScalar* = uint

type
  BitArrayError* = object of Exception
  BitArrayKind = enum inmem, mmap
  FlexArray = UncheckedArray[BitArrayScalar]
  BitArray* = ref object
    size_elements: int
    size_bits*: int
    size_specified*: int
    bitarray*: ptr FlexArray
    read_only: bool
    case kind: BitArrayKind
    of inmem:
      nil
    of mmap:
      mm_filehandle: MemFile


const ONE = BitArrayScalar(1)


# Header -- this is useful for tracking/versioning
# downstream data structures built on TBitArray
const HEADER_SIZE = 1
const DEFAULT_HEADER = BitArrayScalar(0xFFFFFFFFFFFF0025)  # 8 bytes


proc finalize_bitarray(a: BitArray) =
  if not a.bitarray.isNil:
    case a.kind
    of inmem:
      dealloc(a.bitarray)
      a.bitarray = nil
    of mmap:
      a.mm_filehandle.close()


proc close*(a: BitArray) =
  case a.kind
  of inmem:
    discard
  of mmap:
    a.mm_filehandle.close()


proc get_header*(ba: BitArray): BitArrayScalar =
  ## Gets the header of the BitArray object.
  ## This is defined to be a 1-length BitArrayScalar
  ## (uint by default).
  result = ba.bitarray[0]


proc create_bitarray*(size: int, header: BitArrayScalar = DEFAULT_HEADER): BitArray =
  ## Creates an in-memory bitarray using a specified input size.
  ## Note that this will round up to the nearest byte.
  if size < (sizeof(BitArrayScalar) * 8):
    raise newException(BitArrayError,
                       "Minimum size of a bitarray is $#" %
                       [$(sizeof(BitArrayScalar) * 8)])
  let n_elements = size div (sizeof(BitArrayScalar) * 8)
  let n_bits = n_elements * (sizeof(BitArrayScalar) * 8)
  new(result, finalize_bitarray)
  result.kind = inmem
  result.bitarray = cast[ptr FlexArray](alloc0((n_elements + 1) * sizeof(BitArrayScalar)))
  result.size_elements = n_elements
  result.size_bits = n_bits
  result.size_specified = size
  result.bitarray[0] = header


proc create_bitarray*(file: string, size: int = -1, header: BitArrayScalar = DEFAULT_HEADER,
                      read_only: bool = false, enforce_header: bool = true): BitArray =
  ## Creates an mmap-backed bitarray. If the specified file exists
  ## it will be opened, but an exception will be raised if the size
  ## is specified and does not match. If the file does not exist
  ## it will be created.
  if size >= 0 and size < (sizeof(BitArrayScalar) * 8):
    raise newException(BitArrayError,
                       "Minimum size of a bitarray is $#" %
                       [$(sizeof(BitArrayScalar) * 8)])
  var n_elements = size div (sizeof(char) * 8)
  n_elements = n_elements + sizeof(BitArrayScalar)  # For header
  if size mod (sizeof(char) * 8) != 0:
    n_elements += 1
  var mm_file: MemFile
  var new_file = false
  if os.existsFile(file):
    if read_only:
      mm_file = open(file, mode = fmRead, mappedSize = -1)
    else:
      mm_file = open(file, mode = fmReadWrite, mappedSize = -1)
    if size != -1 and mm_file.size != n_elements:
      raise newException(BitArrayError, "Existing mmap file $# does not have the specified size $#. Size is $# instead." % [$file, $n_elements, $mm_file.size])
  else:
    if size == -1:
      raise newException(BitArrayError, "No existing mmap file. Must specify size to create one.")
    mm_file = open(file, mode = fmReadWrite, newFileSize = n_elements)
    new_file = true

  new(result, finalize_bitarray)
  result.kind = mmap
  result.bitarray = cast[ptr FlexArray](mm_file.mem)
  result.size_elements = n_elements
  result.size_bits = mm_file.size * (sizeof(char) * 8) - (sizeof(BitArrayScalar) * 8 * HEADER_SIZE)  # Don't use header in calculation, offset below
  result.size_specified = size
  result.mm_filehandle = mm_file
  result.read_only = read_only
  if new_file:  # Only alter header on creation
    result.bitarray[0] = header
  else:  # enforce header
    let old_header = get_header(result)
    if enforce_header and old_header != header:
      raise newException(BitArrayError, "Headers do not match. Possible version mismatch on underlying bitarray.")


proc `[]=`*(ba: var BitArray, index: int, val: bool) {.inline.} =
  ## Sets the bit at an index to be either 0 (false) or 1 (true)
  when not defined(release):
    if index >= ba.size_bits or index < 0:
      raise newException(BitArrayError, "Specified index is too large.")
  if ba.read_only:
    raise newException(BitArrayError, "Cannot write to a read-only array.")
  let i_element = HEADER_SIZE + index div (sizeof(BitArrayScalar) * 8)
  let i_offset = BitArrayScalar(index mod (sizeof(BitArrayScalar) * 8))
  if val:
    ba.bitarray[i_element] = (ba.bitarray[i_element] or (ONE shl i_offset))
  else:
    ba.bitarray[i_element] = (ba.bitarray[i_element] and (not (ONE shl i_offset)))


proc `[]`*(ba: var BitArray, index: int): bool {.inline.} =
  ## Gets the bit at an index element (returns a bool)
  when not defined(release):
    if index >= ba.size_bits or index < 0:
      raise newException(BitArrayError, "Specified index is too large.")
  let i_element = HEADER_SIZE + index div (sizeof(BitArrayScalar) * 8)
  let i_offset = BitArrayScalar(index mod (sizeof(BitArrayScalar) * 8))
  result = bool((ba.bitarray[i_element] shr i_offset) and ONE)


proc `[]`*(ba: var BitArray, index: Slice): BitArrayScalar {.inline.} =
  ## Get the bits for a slice of the bitarray. Supports slice sizes
  ## up the maximum element size (64 bits by default)
  when not defined(release):
    if index.b >= ba.size_bits or index.a < 0:
      raise newException(BitArrayError, "Specified index is too large.")
    if (index.b - index.a) > (sizeof(BitArrayScalar) * 8):
      raise newException(BitArrayError, "Only slices up to $1 bits are supported." % $(sizeof(BitArrayScalar) * 8))

  let i_element_a = HEADER_SIZE + index.a div (sizeof(BitArrayScalar) * 8)
  let i_offset_a = BitArrayScalar(index.a mod (sizeof(BitArrayScalar) * 8))
  let i_element_b = HEADER_SIZE + index.b div (sizeof(BitArrayScalar) * 8)
  let i_offset_b = BitArrayScalar(sizeof(BitArrayScalar) * 8) - i_offset_a
  result = ba.bitarray[i_element_a] shr i_offset_a
  if i_element_a != i_element_b:  # Combine two slices
    let slice_b = ba.bitarray[i_element_b] shl i_offset_b
    result = result or slice_b
  elif index.a != index.b and index.b < sizeof(BitArrayScalar) * 8 - 1:
    let inner_offset_b = index.b mod (sizeof(BitArrayScalar) * 8)
    result = BitArrayScalar(((1 shl inner_offset_b)-1) or (1 shl inner_offset_b)) and result
  return result  # Fails if this isn't included?


proc `[]=`*(ba: var BitArray, index: Slice, val: BitArrayScalar) {.inline.} =
  ## Set the bits for a slice of the bitarray. Supports slice sizes
  ## up to the maximum element size (64 bits by default)
  ## Note: This inserts using a bitwise-or, it will *not* overwrite previously
  ## set true values!
  when not defined(release):
    if index.b >= ba.size_bits or index.a < 0:
      raise newException(BitArrayError, "Specified index is too large.")
    if (index.b - index.a) > (sizeof(BitArrayScalar) * 8):
      raise newException(BitArrayError, "Only slices up to $1 bits are supported." % $(sizeof(BitArrayScalar) * 8))

  if ba.read_only:
    raise newException(BitArrayError, "Cannot write to a read-only array.")

  # TODO(nbg): Make a macro for handling this and also the if/else in-memory piece
  let i_element_a = HEADER_SIZE + index.a div (sizeof(BitArrayScalar) * 8)
  let i_offset_a = BitArrayScalar(index.a mod (sizeof(BitArrayScalar) * 8))
  let i_element_b = HEADER_SIZE + index.b div (sizeof(BitArrayScalar) * 8)
  let i_offset_b = BitArrayScalar(sizeof(BitArrayScalar) * 8) - i_offset_a

  let insert_a = val shl i_offset_a
  ba.bitarray[i_element_a] = ba.bitarray[i_element_a] or insert_a
  if i_element_a != i_element_b:
    let insert_b = val shr i_offset_b
    ba.bitarray[i_element_b] = ba.bitarray[i_element_b] or insert_b


proc `$`*(ba: BitArray): string =
  ## Print the number of bits and elements in the bitarray (elements are currently defined as 8-bit chars)
  result = ("BitArray with $1 bits and $2 unique elements. In-memory?: $3." %
            [$ba.size_bits, $ba.size_elements, $ba.kind])


when isMainModule:
  echo("Testing bitarray.nim code.")
  when not defined(release):
    let n_tests: int = int(1e6)
    let n_bits: int = int(2e9)  # ~240MB, i.e., much larger than L3 cache
  else:
    let n_tests = int(1e8)
    let n_bits = int(2e9)

  block: # test specific slicing
    var ba = create_bitarray(64)
    ba[0] = true
    ba[2] = true
    ba[7] = true
    assert ba[0..63] == 133, "incorrect result: " & $ba[0..63]
    assert ba[0..4] == 5, "incorrect result: " & $ba[0..4]
    assert ba[1..4] == 2, "incorrect result: " & $ba[1..4]


  var bitarray_a = create_bitarray(n_bits)
  bitarray_a[0] = true
  bitarray_a[1] = true
  bitarray_a[2] = true

  var bitarray_b = create_bitarray("/tmp/ba.mmap", size=n_bits)
  bitarray_b.bitarray[3] = 4

  # Test range lookups/inserts
  bitarray_a[65] = true
  doAssert bitarray_a[65]
  doAssert bitarray_a[2..66] == BitArrayScalar(-9223372036854775807)  # Lexer error prevents using 9223372036854775809'u64 directly... ugh

  bitarray_a[131] = true
  bitarray_a[194] = true
  assert bitarray_a[2..66] == bitarray_a[131..194]
  let slice_value = bitarray_a[131..194]
  bitarray_a[270..333] = slice_value
  bitarray_a[400..463] = BitArrayScalar(-9223372036854775807)
  assert bitarray_a[131..194] == bitarray_a[270..333]
  assert bitarray_a[131..194] == bitarray_a[400..463]

  # Seed RNG
  randomize(2882)  # Seed the RNG
  var n_test_positions = newSeq[int](n_tests)

  for i in 0..(n_tests - 1):
    n_test_positions[i] = rand(n_bits)

  # Timing tests
  var start_time, end_time: float
  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    bitarray_a[n_test_positions[i]] = true
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to insert ", n_tests, " items (in-memory).")

  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    bitarray_b[n_test_positions[i]] = true
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to insert ", n_tests, " items (mmap-backed).")

  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    doAssert bitarray_a[n_test_positions[i]]
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to lookup ", n_tests, " items (in-memory).")

  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    doAssert bitarray_a[n_test_positions[i]]
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to lookup ", n_tests, " items (mmap-backed).")

  # Attempt to reopen bitarray and write to it
  bitarray_b[0] = false
  bitarray_b.mm_filehandle.close()
  var bitarray_c = create_bitarray("/tmp/ba.mmap", size=n_bits, read_only=true)
  try:
    bitarray_c[0] = true
    doAssert false
  except BitArrayError:
    doAssert true
  doAssert bitarray_c[0] == false

  # Header testing; first assert get_header is default
  doAssert bitarray_a.get_header() == DEFAULT_HEADER
  let new_header = BitArrayScalar(0xFFFFFFFFFFFFFEEE)
  var bitarray_d = create_bitarray(100000, header = new_header)
  doAssert bitarray_d.get_header() == new_header

  # Test that header enforcement works
  try:
    discard create_bitarray("/tmp/ba.mmap", header=BitArrayScalar(0))
    doAssert false
  except BitArrayError:
    doAssert true

  # Test that bit arrays < sizeof(BitArrayScalar) fail
  try:
    var m = createBitArray(8)
    discard m
    doAssert false
  except BitArrayError:
    doAssert true
  var bitarray_64 = createBitArray(64)
  doAssert bitarray_64.size_bits == 64

  # Test clearing bits
  var bitarray_e = createBitArray(64)
  bitarray_e[1] = true
  bitarray_e[2] = false
  doAssert bitarray_e[1] == true

  echo("All tests successfully completed.")
