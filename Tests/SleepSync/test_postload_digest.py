#!/usr/bin/env python3
"""Pure synthetic Mach-O tests; no Apple payload, compiler, or device required."""

import hashlib
import importlib.util
from pathlib import Path
import struct
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "Modules/SleepSync/postload_digest.py"
SPEC = importlib.util.spec_from_file_location("postload_digest", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

TEXT = b"__TEXT" + b"\0" * 10
BRAND = 0x1122334455667788  # Synthetic test input, not a discovered device brand.
SIGNATURE_OFFSET = 5000  # Exercises a complete page and a partial final page.
MARKER = 32 + 72 + 24


def pack(data, offset, fmt, *values):
    struct.pack_into(fmt, data, offset, *values)


def fixture(subtype=0x80000002, hash_types=(1, 2), version=0x20400,
            code_limit=SIGNATURE_OFFSET, page_exp=12):
    """Independent encoder of the minimal reviewed signed dylib structure."""
    headers = {0x20001: 44, 0x20100: 48, 0x20200: 52, 0x20300: 64,
               0x20400: 88, 0x20500: 96}
    header_size = headers[version]
    page_size = 1 << page_exp
    page_count = (code_limit + page_size - 1) // page_size
    code = bytearray(code_limit)
    pack(code, 0, "<8I", 0xFEEDFACF, 0x0100000C, subtype, 6, 2, 168, 0, 0)
    pack(code, 32, "<II16s4Q4I", 0x19, 152, TEXT, 0, 8192,
         0, code_limit, 5, 5, 1, 0)
    pack(code, 104, "<16s16sQQ8I", b"__text", TEXT, 256,
         code_limit - 256, 256, 2, 0, 0, 0, 0, 0, 0)
    for offset in range(256, code_limit):
        code[offset] = (offset * 37 + 19) % 256
    # Compute signature size before hashing the LC_CODE_SIGNATURE command.
    lengths = [header_size + 8 + page_count * {1: 20, 2: 32, 3: 20}[ht]
               for ht in hash_types]
    signature_size = 12 + 8 * len(hash_types) + sum(lengths)
    pack(code, 184, "<4I", 0x1D, 16, code_limit, signature_size)
    signature = bytearray(signature_size)
    pack(signature, 0, ">III", 0xFADE0CC0, signature_size, len(hash_types))
    child_offset = 12 + 8 * len(hash_types)
    hashes = {}
    directories = {}
    for index, (hash_type, length) in enumerate(zip(hash_types, lengths)):
        hash_size = {1: 20, 2: 32, 3: 20}[hash_type]
        hash_offset = header_size + 8
        pack(signature, 12 + index * 8, ">II",
             0 if index == 0 else 0x1000 + index - 1, child_offset)
        pack(signature, child_offset, ">9I4BI", 0xFADE0C02, length, version,
             0, hash_offset, header_size, 0, page_count, code_limit,
             hash_size, hash_type, 0, page_exp, 0)
        signature[child_offset + header_size:child_offset + header_size + 8] = b"fixture\0"
        algorithm = "sha1" if hash_type == 1 else "sha256"
        hash_start = child_offset + hash_offset
        for page in range(page_count):
            digest = hashlib.new(algorithm, code[page * page_size:min((page + 1) * page_size,
                                                                        len(code))]).digest()[:hash_size]
            signature[hash_start + page * hash_size:hash_start + (page + 1) * hash_size] = digest
        hashes[hash_type] = code_limit + hash_start
        directories[hash_type] = code_limit + child_offset
        child_offset += length
    return bytes(code + signature), hashes, directories


def fat_fixture(reverse=False):
    ordinary, _, _ = fixture(subtype=0)
    enhanced, hashes, directories = fixture()
    slices = [(ordinary, 0), (enhanced, 0x80000002)]
    if reverse:
        slices.reverse()
    result = bytearray(4096)
    pack(result, 0, ">II", 0xCAFEBABE, 2)
    bases = []
    for index, (binary, subtype) in enumerate(slices):
        base = (len(result) + 4095) // 4096 * 4096
        result.extend(b"\0" * (base - len(result)))
        pack(result, 8 + index * 20, ">5I", 0x0100000C, subtype, base, len(binary), 12)
        result.extend(binary)
        bases.append((base, len(binary), subtype))
    return bytes(result), bases, hashes


class PostloadTests(unittest.TestCase):
    def assert_rejected(self, binary, brand=BRAND):
        with self.assertRaises(ValueError):
            MODULE.modeled_postload(bytes(binary), brand)

    def test_thin_exact_reference_bytes(self):
        original, hashes, _ = fixture()
        output = MODULE.modeled_postload(original, BRAND)
        expected = bytearray(original)
        expected[MARKER:MARKER + 8] = bytes.fromhex("8877665544332211")
        expected[hashes[2]:hashes[2] + 32] = hashlib.sha256(expected[:4096]).digest()
        self.assertEqual(output, bytes(expected))
        allowed = set(range(MARKER, MARKER + 8)) | set(range(hashes[2], hashes[2] + 32))
        changes = {i for i, (a, b) in enumerate(zip(original, output)) if a != b}
        self.assertLessEqual(changes, allowed)
        self.assertEqual(len(changes), 40)  # Fixed fixture has no coincident hash bytes.
        self.assertEqual(len(output), len(original))
        self.assertEqual(output[hashes[1]:hashes[1] + 40], original[hashes[1]:hashes[1] + 40])
        self.assertNotEqual(hashlib.sha1(output[:4096]).digest(), output[hashes[1]:hashes[1] + 20])
        self.assertEqual(hashlib.sha256(output[4096:SIGNATURE_OFFSET]).digest(),
                         output[hashes[2] + 32:hashes[2] + 64])

    def test_sha256_only_and_versioned_headers(self):
        for version in (0x20001, 0x20100, 0x20200, 0x20300, 0x20400, 0x20500):
            with self.subTest(version=hex(version)):
                original, hashes, _ = fixture(hash_types=(2,), version=version)
                output = MODULE.modeled_postload(original, 1)
                self.assertEqual(output[MARKER:MARKER + 8], b"\1" + b"\0" * 7)
                self.assertEqual(output[hashes[2]:hashes[2] + 32], hashlib.sha256(output[:4096]).digest())

    def test_selects_sha256_independent_of_slot_order(self):
        original, hashes, _ = fixture(hash_types=(2, 1))
        output = MODULE.modeled_postload(original, BRAND)
        expected = bytearray(original)
        expected[MARKER:MARKER + 8] = BRAND.to_bytes(8, "little")
        expected[hashes[2]:hashes[2] + 32] = hashlib.sha256(expected[:4096]).digest()
        self.assertEqual(output, bytes(expected))
        self.assertEqual(output[hashes[1]:hashes[1] + 40], original[hashes[1]:hashes[1] + 40])

    def test_rejects_hash_valid_noncanonical_segname_padding(self):
        original, hashes, _ = fixture()
        for offset in (47, 127, MARKER, MARKER + 7):
            changed = bytearray(original)
            changed[offset] = 1
            # Independently repair the original signature to ensure rejection
            # is structural, not merely a consequence of a stale page hash.
            changed[hashes[1]:hashes[1] + 20] = hashlib.sha1(changed[:4096]).digest()
            changed[hashes[2]:hashes[2] + 32] = hashlib.sha256(changed[:4096]).digest()
            self.assert_rejected(changed)

    def test_fat_changes_only_arm64e_in_either_order(self):
        for reverse in (False, True):
            original, bases, hashes = fat_fixture(reverse)
            output = MODULE.modeled_postload(original, BRAND)
            expected = bytearray(original)
            for base, size, subtype in bases:
                if subtype == 0:
                    self.assertEqual(output[base:base + size], original[base:base + size])
                else:
                    expected[base:base + size] = MODULE.modeled_postload(original[base:base + size], BRAND)
            self.assertEqual(output, bytes(expected))

    def test_partial_page_zero_and_larger_code_pages(self):
        for limit, exponent in ((512, 12), (4096, 12), (5000, 14)):
            original, hashes, _ = fixture(code_limit=limit, page_exp=exponent)
            output = MODULE.modeled_postload(original, BRAND)
            expected = bytearray(original)
            expected[MARKER:MARKER + 8] = BRAND.to_bytes(8, "little")
            expected[hashes[2]:hashes[2] + 32] = hashlib.sha256(
                expected[:min(1 << exponent, limit)]).digest()
            self.assertEqual(output, bytes(expected))
        # A valid signature with tiny pages is still an unreviewed transform:
        # the brand would lie outside page zero.
        self.assert_rejected(fixture(page_exp=7)[0])

    def test_hash_api(self):
        original, _, _ = fixture()
        postload = MODULE.modeled_postload(original, BRAND)
        self.assertEqual(MODULE.allowed_hashes(original), (hashlib.sha256(original).hexdigest(),))
        self.assertEqual(MODULE.allowed_hashes(original, BRAND),
                         tuple(hashlib.sha256(data).hexdigest() for data in (original, postload)))
        with self.assertRaises(ValueError):
            MODULE.allowed_hashes(b"not Mach-O")

    def test_explicit_uint64_brand(self):
        original, _, _ = fixture()
        for bad in (None, True, False, 0, -1, 1 << 64, 1.0, "1", b"12345678"):
            with self.subTest(brand=bad):
                self.assert_rejected(original, bad)
        output = MODULE.modeled_postload(original, (1 << 64) - 1)
        self.assertEqual(output[MARKER:MARKER + 8], b"\xff" * 8)

    def test_corrupt_original_hashes_all_pages_and_directories(self):
        original, hashes, _ = fixture()
        for offset in (300, 4500, hashes[1], hashes[1] + 20, hashes[2], hashes[2] + 32):
            corrupted = bytearray(original)
            corrupted[offset] ^= 1
            self.assert_rejected(corrupted)
        # The unmodified arm64 slice is validated too, not just arm64e.
        original, bases, _ = fat_fixture()
        corrupted = bytearray(original)
        corrupted[bases[0][0] + 4500] ^= 1
        self.assert_rejected(corrupted)

    def test_no_arm64e_and_unknown_containers(self):
        ordinary, _, _ = fixture(subtype=0)
        self.assert_rejected(ordinary)
        for magic in (b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            self.assert_rejected(magic + ordinary[4:])
        for length in range(32):
            self.assert_rejected(ordinary[:length])
        with self.assertRaises(ValueError):
            MODULE.modeled_postload(bytearray(ordinary), BRAND)

    def test_malformed_commands_and_sections(self):
        original, _, _ = fixture()
        cases = [(12, "<I", 2), (16, "<I", 3), (20, "<I", 169),
                 (36, "<I", 0), (36, "<I", 153), (36, "<I", 0xFFFFFFF8),
                 (96, "<I", 2), (144, "<Q", 1 << 60),
                 (152, "<I", SIGNATURE_OFFSET + 10), (188, "<I", 24),
                 (192, "<I", 100), (196, "<I", 0xFFFFFFFF)]
        for offset, fmt, value in cases:
            with self.subTest(offset=offset, value=value):
                corrupted = bytearray(original)
                pack(corrupted, offset, fmt, value)
                self.assert_rejected(corrupted)
        for offset in (40 + 7, 120, MARKER, MARKER + 7):
            corrupted = bytearray(original)
            corrupted[offset] = 1
            self.assert_rejected(corrupted)
        self.assert_rejected(MODULE.modeled_postload(original, BRAND))

    def test_malformed_superblob_and_code_directories(self):
        original, hashes, directories = fixture()
        sig = SIGNATURE_OFFSET
        cd = directories[2]
        cases = [(sig, ">I", 0), (sig + 4, ">I", 0xFFFFFFFF),
                 (sig + 8, ">I", 0xFFFFFFFF), (sig + 16, ">I", 0),
                 (sig + 20, ">I", 0), (sig + 24, ">I", 0xFFFFFFFF),
                 (cd + 4, ">I", 8), (cd + 8, ">I", 0x20600),
                 (cd + 8, ">I", 0x20401),
                 (cd + 16, ">I", 4), (cd + 20, ">I", 0),
                 (cd + 24, ">I", 0xFFFFFFFF), (cd + 28, ">I", 1),
                 (cd + 32, ">I", SIGNATURE_OFFSET - 1),
                 (cd + 36, ">B", 20), (cd + 37, ">B", 3),
                 (cd + 39, ">B", 0), (cd + 39, ">B", 31),
                 (cd + 44, ">I", 1), (cd + 48, ">I", 0xFFFFFFFF),
                 (cd + 56, ">Q", SIGNATURE_OFFSET + 1)]
        for offset, fmt, value in cases:
            with self.subTest(offset=offset, value=value):
                corrupted = bytearray(original)
                pack(corrupted, offset, fmt, value)
                self.assert_rejected(corrupted)
        for hash_types in ((1,), (2, 2), (1, 2, 2), (3, 2)):
            self.assert_rejected(fixture(hash_types=hash_types)[0])
        for cut in (1, 8, 40, len(original) - 32):
            self.assert_rejected(original[:-cut])

    def test_malformed_fat_bounds_and_descriptors(self):
        original, bases, _ = fat_fixture()
        cases = [(4, 1), (4, 3), (8, 7), (12, 0x80000002),
                 (16, 0), (20, 0xFFFFFFFF), (24, 32),
                 (36, bases[0][0]), (40, 0xFFFFFFFF), (32, 0)]
        for offset, value in cases:
            with self.subTest(offset=offset, value=value):
                corrupted = bytearray(original)
                pack(corrupted, offset, ">I", value)
                self.assert_rejected(corrupted)
        corrupted = bytearray(original)
        pack(corrupted, bases[1][0] + 8, "<I", 0)
        self.assert_rejected(corrupted)


if __name__ == "__main__":
    unittest.main()
