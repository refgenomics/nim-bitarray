import memfiles
from os import nil
from strutils import `%`, formatFloat, ffDecimal, toBin
import unsigned
from math import random, randomize
from times import nil


# Type declarations
type
  TBitScalar* = uint

type
  EBitarray* = object of EBase
  TBitarrayKind = enum inmem, mmap
  TFlexArray {.unchecked.} = array[0..0, TBitScalar]
  TBitarray* = ref object
    size_elements: int
    size_bits*: int
    size_specified*: int
    bitarray*: ptr TFlexArray
    read_only: bool
    case kind: TBitarrayKind
    of inmem:
      nil
    of mmap:
      mm_filehandle: TMemFile


const ONE = TBitScalar(1)

# Note need to change 3rd create_bitarray method's
# header setter (uses [0]) if changing this
const HEADER_SIZE = 1
const DEFAULT_HEADER = TBitScalar(0xFFFFFFFFFFFFFFFF)  # 8 bytes


proc finalize_bitarray(a: TBitarray) =
  if not a.bitarray.isNil:
    case a.kind
    of inmem:
      dealloc(a.bitarray)
      a.bitarray = nil
    of mmap:
      a.mm_filehandle.close()


proc close*(a: TBitarray) =
  case a.kind
  of inmem:
    discard
  of mmap:
    a.mm_filehandle.close()


proc create_bitarray*(size: int, header: TBitScalar = DEFAULT_HEADER): TBitarray =
  ## Creates an in-memory bitarray using a specified input size.
  ## Note that this will round up to the nearest byte.
  let n_elements = size div (sizeof(TBitScalar) * 8)
  let n_bits = n_elements * (sizeof(TBitScalar) * 8)
  new(result, finalize_bitarray)
  result.kind = inmem
  result.bitarray = cast[ptr TFlexArray](alloc0(n_elements * sizeof(TBitScalar)))
  result.size_elements = n_elements
  result.size_bits = n_bits
  result.size_specified = size
  result.bitarray[0] = header


proc create_bitarray*(file: string, size: int = -1, header: TBitScalar = DEFAULT_HEADER, read_only: bool = false): TBitarray =
  ## Creates an mmap-backed bitarray. If the specified file exists
  ## it will be opened, but an exception will be raised if the size
  ## is specified and does not match. If the file does not exist
  ## it will be created.
  var n_elements = size div (sizeof(char) * 8)
  if size mod (sizeof(char) * 8) != 0:
    n_elements += 1
  var mm_file: TMemFile
  if os.existsFile(file):
    mm_file = open(file, mode = fmReadWrite, mappedSize = -1)
    if size != -1 and mm_file.size != n_elements:
      raise newException(EBitarray, "Existing mmap file $# does not have the specified size $#. Size is $# instead." % [$file, $n_elements, $mm_file.size])
  else:
    if size == -1:
      raise newException(EBitarray, "No existing mmap file. Must specify size to create one.")
    mm_file = open(file, mode = fmReadWrite, newFileSize = n_elements)

  new(result, finalize_bitarray)
  result.kind = mmap
  result.bitarray = cast[ptr TFlexArray](mm_file.mem)
  result.size_elements = n_elements
  result.size_bits = mm_file.size * (sizeof(char) * 8)
  result.size_specified = size
  result.mm_filehandle = mm_file
  result.read_only = read_only
  result.bitarray[0] = header


proc get_header*(ba: TBitarray): TBitScalar =
  result = ba.bitarray[0]


proc `[]=`*(ba: var TBitarray, index: int, val: bool) {.inline.} =
  ## Sets the bit at an index to be either 0 (false) or 1 (true)
  when not defined(release):
    if index >= ba.size_bits or index < 0:
      raise newException(EBitarray, "Specified index is too large.")
  if ba.read_only:
    raise newException(EBitarray, "Cannot write to a read-only array.")
  let i_element = HEADER_SIZE + index div (sizeof(TBitScalar) * 8)
  let i_offset = TBitScalar(index mod (sizeof(TBitScalar) * 8))
  if val:
    ba.bitarray[i_element] = (ba.bitarray[i_element] or (ONE shl i_offset))
  else:
    ba.bitarray[i_element] = (ba.bitarray[i_element] and ((not ONE) shl i_offset))


proc `[]`*(ba: var TBitarray, index: int): bool {.inline.} =
  ## Gets the bit at an index element (returns a bool)
  when not defined(release):
    if index >= ba.size_bits or index < 0:
      raise newException(EBitarray, "Specified index is too large.")
  let i_element = HEADER_SIZE + index div (sizeof(TBitScalar) * 8)
  let i_offset = TBitScalar(index mod (sizeof(TBitScalar) * 8))
  result = bool((ba.bitarray[i_element] shr i_offset) and ONE)


proc `[]`*(ba: var TBitarray, index: TSlice): TBitScalar {.inline.} =
  ## Get the bits for a slice of the bitarray. Supports slice sizes
  ## up the maximum element size (64 bits by default)
  when not defined(release):
    if index.b >= ba.size_bits or index.a < 0:
      raise newException(EBitarray, "Specified index is too large.")
    if (index.b - index.a) > (sizeof(TBitScalar) * 8):
      raise newException(EBitarray, "Only slices up to $1 bits are supported." % $(sizeof(TBitScalar) * 8))

  let i_element_a = HEADER_SIZE + index.a div (sizeof(TBitScalar) * 8)
  let i_offset_a = TBitScalar(index.a mod (sizeof(TBitScalar) * 8))
  let i_element_b = HEADER_SIZE + index.b div (sizeof(TBitScalar) * 8)
  let i_offset_b = TBitScalar(sizeof(TBitScalar) * 8) - i_offset_a
  var result = ba.bitarray[i_element_a] shr i_offset_a
  if i_element_a != i_element_b:  # Combine two slices
    let slice_b = ba.bitarray[i_element_b] shl i_offset_b
    result = result or slice_b
  return result  # Fails if this isn't included?


proc `[]=`*(ba: var TBitarray, index: TSlice, val: TBitScalar) {.inline.} =
  ## Set the bits for a slice of the bitarray. Supports slice sizes
  ## up to the maximum element size (64 bits by default)
  ## Note: This inserts using a bitwise-or, it will *not* overwrite previously
  ## set true values!
  when not defined(release):
    if index.b >= ba.size_bits or index.a < 0:
      raise newException(EBitarray, "Specified index is too large.")
    if (index.b - index.a) > (sizeof(TBitScalar) * 8):
      raise newException(EBitarray, "Only slices up to $1 bits are supported." % $(sizeof(TBitScalar) * 8))

  if ba.read_only:
    raise newException(EBitarray, "Cannot write to a read-only array.")

  # TODO(nbg): Make a macro for handling this and also the if/else in-memory piece
  let i_element_a = HEADER_SIZE + index.a div (sizeof(TBitScalar) * 8)
  let i_offset_a = TBitScalar(index.a mod (sizeof(TBitScalar) * 8))
  let i_element_b = HEADER_SIZE + index.b div (sizeof(TBitScalar) * 8)
  let i_offset_b = TBitScalar(sizeof(TBitScalar) * 8) - i_offset_a

  let insert_a = val shl i_offset_a
  ba.bitarray[i_element_a] = ba.bitarray[i_element_a] or insert_a
  if i_element_a != i_element_b:
    let insert_b = val shr i_offset_b
    ba.bitarray[i_element_b] = ba.bitarray[i_element_b] or insert_b


proc `$`*(ba: TBitarray): string =
  ## Print the number of bits and elements in the bitarray (elements are currently defined as 8-bit chars)
  result = ("Bitarray with $1 bits and $2 unique elements. In-memory?: $3." %
            [$ba.size_bits, $ba.size_elements, $ba.kind])


when isMainModule:
  echo("Testing bitarray.nim code.")
  let n_tests: int = int(1e6)
  let n_bits: int = int(2e9)  # ~240MB, i.e., much larger than L3 cache

  var bitarray = create_bitarray(n_bits)
  bitarray[0] = true
  bitarray[1] = true
  bitarray[2] = true

  var bitarray_b = create_bitarray("/tmp/ba.mmap", size=n_bits)
  bitarray_b.bitarray[3] = 4

  # # Test range lookups/inserts
  bitarray[65] = true
  doAssert bitarray[65]
  doAssert bitarray[2..66] == TBitScalar(-9223372036854775807)  # Lexer error prevents using 9223372036854775809'u64 directly... ugh

  bitarray[131] = true
  bitarray[194] = true
  assert bitarray[2..66] == bitarray[131..194]
  let slice_value = bitarray[131..194]
  bitarray[270..333] = slice_value
  bitarray[400..463] = TBitScalar(-9223372036854775807)
  assert bitarray[131..194] == bitarray[270..333]
  assert bitarray[131..194] == bitarray[400..463]

  # Seed RNG
  randomize(2882)  # Seed the RNG
  var n_test_positions = newSeq[int](n_tests)

  for i in 0..(n_tests - 1):
    n_test_positions[i] = random(n_bits)

  # Timing tests
  var start_time, end_time: float
  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    bitarray[n_test_positions[i]] = true
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to insert ", n_tests, " items (in-memory).")

  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    bitarray_b[n_test_positions[i]] = true
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to insert ", n_tests, " items (mmap-backed).")

  var bit_value: bool
  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    doAssert bitarray[n_test_positions[i]]
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to lookup ", n_tests, " items (in-memory).")

  start_time = times.cpuTime()
  for i in 0..(n_tests - 1):
    doAssert bitarray[n_test_positions[i]]
  end_time = times.cpuTime()
  echo("Took ", formatFloat(end_time - start_time, format = ffDecimal, precision = 4), " seconds to lookup ", n_tests, " items (mmap-backed).")

  # Attempt to reopen bitarray and write to it
  bitarray_b[0] = false
  bitarray_b.mm_filehandle.close()
  var bitarray_c = create_bitarray("/tmp/ba.mmap", size=n_bits, read_only=true)
  try:
    bitarray_c[0] = true
    doAssert false
  except EBitarray:
    doAssert true
  doAssert bitarray_c[0] == false

  # Header testing; first assert get_header is default
  doAssert bitarray.get_header() == DEFAULT_HEADER
  let new_header = TBitScalar(0xFFFFFFFFFFFFFEEE)
  var bitarray_d = create_bitarray(100000, header = new_header)
  doAssert bitarray_d.get_header() == new_header

  echo("All tests successfully completed.")
