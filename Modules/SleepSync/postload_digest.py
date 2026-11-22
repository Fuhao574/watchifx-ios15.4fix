"""Offline byte model of the reviewed RootHide post-load transform.

This is deliberately not a general Mach-O editor or signature repair tool. It
accepts an original, page-hash-valid arm64e MH_DYLIB, optionally in a two-slice
FAT_MAGIC container with arm64. The only writes are the first __TEXT section's
segname tail and the unique SHA256 CodeDirectory's page-zero hash. In particular,
an existing SHA1 CodeDirectory is preserved, including its now-stale page zero.

The model follows the reviewed recdhash.m behavior, not a claim about a currently
installed loader. No file I/O, device access, signing, or brand discovery occurs.
Callers must supply the build's explicit uint64 brand; it is never inferred.
"""

import hashlib
import struct


_ARM64 = 0x0100000C
_ARM64E = 0x80000002
_TEXT = b"__TEXT" + b"\0" * 10


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _span(start, length, end, label, minimum=0):
    _require(minimum <= start <= end and 0 <= length <= end - start,
             "out-of-bounds " + label)
    return start + length


def _unpack(fmt, data, offset, end, label):
    _span(offset, struct.calcsize(fmt), end, label)
    return struct.unpack_from(fmt, data, offset)


def _disjoint(ranges, label):
    previous = 0
    for start, end in sorted(ranges):
        _require(start >= previous, "overlapping " + label)
        previous = end


def _slices(binary):
    """Return bounded slice descriptors; reject all unreviewed containers."""
    magic = binary[:4]
    if magic == b"\xcf\xfa\xed\xfe":
        return [(0, len(binary), _ARM64, _ARM64E)]
    _require(magic == b"\xca\xfe\xba\xbe", "unknown Mach-O container")
    count, = _unpack(">I", binary, 4, len(binary), "fat header")
    _require(count == 2, "expected exactly two fat slices")
    table_end = _span(8, 20 * count, len(binary), "fat architecture table")
    slices = []
    for index in range(count):
        cpu, subtype, offset, size, alignment = _unpack(
            ">5I", binary, 8 + 20 * index, table_end, "fat architecture")
        _require(cpu == _ARM64 and subtype in (0, _ARM64E),
                 "unknown fat architecture")
        _require(alignment <= 31 and offset % (1 << alignment) == 0,
                 "invalid fat alignment")
        _span(offset, size, len(binary), "fat slice", table_end)
        _require(size >= 32, "short fat slice")
        slices.append((offset, size, cpu, subtype))
    _require({item[3] for item in slices} == {0, _ARM64E},
             "expected one arm64 and one arm64e slice")
    _disjoint([(offset, offset + size) for offset, size, _, _ in slices],
              "fat slices")
    return slices


def _directory(data, start, end, signature_offset, slice_base):
    (magic, length, version, flags, hash_offset, ident_offset, special_count,
     code_count, code_limit, hash_size, hash_type, platform, page_exp,
     spare) = _unpack(">9I4BI", data, start, end, "CodeDirectory header")
    _require(magic == 0xFADE0C02 and start + length == end,
             "invalid CodeDirectory length")
    _require(version in (0x20001, 0x20100, 0x20200, 0x20300, 0x20400, 0x20500),
             "unsupported CodeDirectory version")
    header_size = 44
    for threshold, size in ((0x20100, 48), (0x20200, 52), (0x20300, 64),
                            (0x20400, 88), (0x20500, 96)):
        if version >= threshold:
            header_size = size
    _span(start, header_size, end, "versioned CodeDirectory header")
    _require(spare == 0, "nonzero CodeDirectory spare")
    if version >= 0x20100:
        scatter, = _unpack(">I", data, start + 44, end, "scatter offset")
        _require(scatter == 0, "scatter CodeDirectory not modeled")
    team = 0
    if version >= 0x20200:
        team, = _unpack(">I", data, start + 48, end, "team offset")
    if version >= 0x20300:
        spare3, limit64 = _unpack(">IQ", data, start + 52, end, "64-bit limit")
        _require(spare3 == 0 and limit64 in (0, code_limit),
                 "unsupported 64-bit code limit")
    if version >= 0x20500:
        pre_encrypt, = _unpack(">I", data, start + 92, end, "pre-encrypt offset")
        _require(pre_encrypt == 0, "pre-encrypt hashes not modeled")
    _require((hash_type, hash_size) in ((1, 20), (2, 32)),
             "unsupported CodeDirectory hash type or size")
    _require(code_limit == signature_offset and code_limit > 0,
             "CodeDirectory codeLimit must equal signature offset")
    _require(1 <= page_exp <= 30, "unsupported code page size")
    page_size = 1 << page_exp
    _require(code_count == (code_limit + page_size - 1) // page_size,
             "CodeDirectory page count mismatch")
    hash_start = start + hash_offset
    special_start = hash_start - special_count * hash_size
    _span(special_start, special_count * hash_size, end, "special hashes",
          start + header_size)
    _span(hash_start, code_count * hash_size, end, "code hashes",
          start + header_size)
    _require(ident_offset != 0, "missing CodeDirectory identifier")
    for offset in (ident_offset,) + ((team,) if team else ()):
        _require(header_size <= offset < special_start - start,
                 "invalid CodeDirectory string offset")
        _require(data.find(b"\0", start + offset, special_start) != -1,
                 "unterminated CodeDirectory string")
    algorithm = "sha1" if hash_type == 1 else "sha256"
    for page in range(code_count):
        low = slice_base + page * page_size
        high = slice_base + min((page + 1) * page_size, code_limit)
        expected = hashlib.new(algorithm, data[low:high]).digest()
        stored = data[hash_start + page * hash_size:
                      hash_start + (page + 1) * hash_size]
        _require(expected == stored, "original code page hash mismatch")
    return hash_type, hash_start, page_size


def _signature(data, start, size, signature_offset, slice_base):
    end = start + size
    magic, length, count = _unpack(">III", data, start, end, "SuperBlob header")
    _require(magic == 0xFADE0CC0 and 12 <= length <= size,
             "invalid embedded signature SuperBlob")
    blob_end = start + length
    table_end = _span(start + 12, count * 8, blob_end, "SuperBlob index")
    _require(not any(data[blob_end:end]), "nonzero signature trailing padding")
    ranges, slots, directories = [], set(), []
    for index in range(count):
        slot, offset = _unpack(">II", data, start + 12 + index * 8,
                               table_end, "SuperBlob entry")
        _require(slot not in slots, "duplicate signature slot")
        slots.add(slot)
        child = start + offset
        _span(child, 8, blob_end, "signature child header", table_end)
        child_magic, child_size = _unpack(">II", data, child, blob_end,
                                           "signature child")
        _require(child_size >= 8, "short signature child")
        child_end = _span(child, child_size, blob_end, "signature child", table_end)
        ranges.append((child, child_end))
        is_cd_slot = slot == 0 or 0x1000 <= slot <= 0x1005
        _require(is_cd_slot == (child_magic == 0xFADE0C02),
                 "CodeDirectory slot/magic mismatch")
        if is_cd_slot:
            directories.append(_directory(data, child, child_end,
                                          signature_offset, slice_base))
    _disjoint(ranges, "signature children")
    types = [item[0] for item in directories]
    _require(types.count(2) == 1 and types.count(1) <= 1,
             "expected unique SHA256 CodeDirectory (optional unique SHA1)")
    _require(0 in slots, "missing primary CodeDirectory")
    return next(item for item in directories if item[0] == 2)


def _plan(binary):
    _require(isinstance(binary, bytes), "binary must be bytes")
    patches = []
    for base, size, expected_cpu, expected_subtype in _slices(binary):
        end = base + size
        (magic, cpu, subtype, filetype, count, commands_size,
         flags, reserved) = _unpack("<8I", binary, base, end, "Mach-O header")
        _require(magic == 0xFEEDFACF and cpu == expected_cpu
                 and subtype == expected_subtype, "slice architecture mismatch")
        _require(filetype == 6 and reserved == 0, "expected MH_DYLIB header")
        commands_end = _span(base + 32, commands_size, end, "load commands")
        _require(count > 0 and count <= commands_size // 8,
                 "invalid load command count")
        position = base + 32
        marker, signature = None, None
        file_ranges = []
        for _ in range(count):
            command, length = _unpack("<II", binary, position, commands_end,
                                       "load command header")
            _require(length >= 8 and length % 8 == 0, "invalid command size")
            command_end = _span(position, length, commands_end, "load command")
            if command == 0x19:  # LC_SEGMENT_64
                _span(position, 72, command_end, "segment header")
                name = binary[position + 8:position + 24]
                vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sections, segflags = (
                    _unpack("<4Q4I", binary, position + 24, command_end,
                            "segment fields"))
                _require(length == 72 + sections * 80, "invalid section table size")
                _span(base + fileoff, filesize, end, "segment file range", base)
                if filesize:
                    file_ranges.append((fileoff, fileoff + filesize))
                for section in range(sections):
                    sec = position + 72 + section * 80
                    address, secsize, offset, alignment, reloff, nreloc, secflags = (
                        _unpack("<QQ5I", binary, sec + 32, command_end,
                                "section fields"))
                    _require(alignment <= 31, "invalid section alignment")
                    if (secflags & 0xFF) not in (1, 0xC, 0x12):  # zerofill
                        _span(base + offset, secsize, end, "section file range", base)
                        _require(fileoff <= offset and offset + secsize <= fileoff + filesize,
                                 "section outside segment")
                    if nreloc:
                        _span(base + reloff, nreloc * 8, end, "section relocations", base)
                if name.split(b"\0", 1)[0] == b"__TEXT":
                    _require(name == _TEXT and marker is None and sections > 0,
                             "ambiguous or malformed __TEXT segment")
                    _require(fileoff == 0 and filesize >= commands_end - base,
                             "__TEXT does not contain header and commands")
                    first = position + 72
                    _require(binary[first + 16:first + 32] == _TEXT,
                             "first section segname must be unbranded __TEXT")
                    marker = first + 24
            elif command == 0x1D:  # LC_CODE_SIGNATURE
                _require(length == 16 and signature is None,
                         "ambiguous or malformed code signature command")
                signature = _unpack("<II", binary, position + 8, command_end,
                                    "code signature range")
            position = command_end
        _require(position == commands_end, "load command size/count mismatch")
        _require(marker is not None and signature is not None,
                 "missing __TEXT section or code signature")
        offset, sigsize = signature
        _require(offset >= commands_end - base and sigsize >= 12,
                 "signature overlaps load commands")
        _span(base + offset, sigsize, end, "code signature", base)
        _require(offset + sigsize == size, "signature must end at slice boundary")
        _disjoint(file_ranges, "segment file ranges")
        hash_type, hash_start, page_size = _signature(
            binary, base + offset, sigsize, offset, base)
        _require(marker + 8 <= base + min(page_size, offset),
                 "brand marker is not wholly in code page zero")
        if subtype == _ARM64E:
            patches.append((marker, hash_start, base, min(page_size, offset)))
    _require(len(patches) == 1, "expected exactly one arm64e slice")
    return patches


def modeled_postload(binary: bytes, brand: int) -> bytes:
    """Return modeled bytes, or ValueError for any unsupported/invalid layout.

    brand must be an explicit integer in [1, 2**64); bool is not accepted.
    All original code hashes in all slices are checked before any mutation.
    """
    _require(type(brand) is int and 1 <= brand < (1 << 64),
             "brand must be an explicit nonzero uint64 integer")
    plan = _plan(binary)
    result = bytearray(binary)
    for marker, hash_start, base, page_length in plan:
        result[marker:marker + 8] = brand.to_bytes(8, "little")
        result[hash_start:hash_start + 32] = hashlib.sha256(
            result[base:base + page_length]).digest()
    return bytes(result)


def allowed_hashes(binary: bytes, brand=None) -> tuple:
    """Return lowercase whole-file SHA256 hex digests, original then postload.

    With no brand, validate the original and return only its digest. Supplying
    brand explicitly enables the modeled digest; no machine-local input is read.
    These hashes describe bytes, not loader execution or cryptographic trust.
    """
    if brand is None:
        _plan(binary)
        return (hashlib.sha256(binary).hexdigest(),)
    postload = modeled_postload(binary, brand)
    return (hashlib.sha256(binary).hexdigest(), hashlib.sha256(postload).hexdigest())
