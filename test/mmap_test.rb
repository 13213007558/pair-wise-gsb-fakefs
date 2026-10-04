# frozen_string_literal: true

require_relative 'test_helper'

class MmapTest < Minitest::Test
  PAGE_SIZE = 16

  def setup
    FakeFS.activate!
    File.write('file', '0123456789abcdef' * 2)
  end

  def teardown
    FakeFS.deactivate!
    FakeFS::FileSystem.clear
  end

  def test_shared_mapping_shares_pages_with_file_io
    mapping = FakeFS::Mmap.new(
      'file', 32, page_size: PAGE_SIZE,
      prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE
    )

    mapping.write('shared', 16)
    assert_equal 'shared', File.binread('file', 6, 16)

    File.binwrite('file', 'io', 20)
    assert_equal 'shario', mapping.read(6, 16)
  end

  def test_file_object_opens_shared_mapping
    File.open('file', 'r+') do |file|
      mapping = file.mmap(16, page_size: PAGE_SIZE, prot: 'rw')
      mapping.write('x', 0)
    end

    assert_equal "x#{File.binread('file', 15, 1)}", File.binread('file', 16)
  end

  def test_class_constructor_and_keyword_flags_are_supported
    mapping = File.mmap('file', 16, page_size: PAGE_SIZE, flags: :private, prot: :rw)

    assert_predicate mapping, :private?
    assert_equal FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE, mapping.prot
  end

  def test_syscall_style_positional_arguments_are_supported
    mapping = FakeFS::Mmap.new(
      'file', 16, FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE,
      FakeFS::Mmap::MAP_PRIVATE, PAGE_SIZE, page_size: PAGE_SIZE
    )

    assert_equal PAGE_SIZE, mapping.offset
    assert_predicate mapping, :private?
  end

  def test_block_constructor_unmaps_automatically
    mapping = FakeFS::Mmap.open('file', 16, page_size: PAGE_SIZE) do |open_mapping|
      assert_predicate open_mapping, :mapped?
      open_mapping
    end

    refute_predicate mapping, :mapped?
  end

  def test_private_write_uses_copy_on_write_and_does_not_modify_file
    mapping = FakeFS::Mmap.new(
      'file', 32, page_size: PAGE_SIZE, flags: FakeFS::Mmap::MAP_PRIVATE, prot: 'rw'
    )

    assert_equal '0123456789abcdef', mapping.read(16)
    mapping.write('PRIVATE', 0)

    assert_equal 'PRIVATE789abcdef0123456789abcdef', mapping.read(32)
    assert_equal '0123456789abcdef', File.binread('file', 16)
    assert_equal 0, mapping.msync
    assert_equal '0123456789abcdef', File.binread('file', 16)

    mapping.unmap
    assert_equal '0123456789abcdef' * 2, File.binread('file')
  end

  def test_private_pages_do_not_see_later_shared_changes
    mapping = FakeFS::Mmap.new(
      'file', 32, page_size: PAGE_SIZE, flags: FakeFS::Mmap::MAP_PRIVATE, prot: 'rw'
    )

    mapping.setbyte(0, 'X'.ord)
    File.binwrite('file', 'shared')

    assert_equal 'X', mapping.read(1)
    assert_equal 'shared', File.binread('file', 16)
  end

  def test_unmapped_mapping_cannot_be_accessed_or_unmapped_again
    mapping = FakeFS::Mmap.new('file', 16, page_size: PAGE_SIZE)

    mapping.unmap

    assert_raises(FakeFS::Mmap::UnmappedError) { mapping.read }
    assert_raises(FakeFS::Mmap::UnmappedError) { mapping.write('x') }
    assert_raises(FakeFS::Mmap::UnmappedError) { mapping.msync }
    assert_raises(FakeFS::Mmap::UnmappedError) { mapping.unmap }
  end

  def test_page_aligned_offsets_are_required
    error = assert_raises(FakeFS::Mmap::InvalidError) do
      FakeFS::Mmap.new('file', 16, offset: 1, page_size: PAGE_SIZE)
    end
    assert_equal 'offset must be page aligned', error.message

    mapping = FakeFS::Mmap.new('file', 16, offset: PAGE_SIZE, page_size: PAGE_SIZE)
    assert_equal '0123456789abcdef', mapping.read
  end

  def test_protection_flags_enforce_read_and_write_access
    readable = FakeFS::Mmap.new('file', 1, page_size: PAGE_SIZE)
    assert_equal 48, readable[0]
    assert_raises(FakeFS::Mmap::PermissionError) { readable.write('x') }

    writable = FakeFS::Mmap.new(
      'file', 1, page_size: PAGE_SIZE, prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE
    )
    writable[0] = 'Y'
    assert_equal 89, writable[0]

    inaccessible = FakeFS::Mmap.new('file', 1, page_size: PAGE_SIZE, prot: FakeFS::Mmap::PROT_NONE)
    assert_raises(FakeFS::Mmap::PermissionError) { inaccessible.read(1) }
    assert_raises(FakeFS::Mmap::PermissionError) { inaccessible.write('x') }
  end

  def test_byte_and_range_access_uses_binary_data
    mapping = FakeFS::Mmap.new('file', 32, page_size: PAGE_SIZE, prot: 'rw')

    mapping[0] = 1
    mapping[1..2] = 'XY'
    mapping[3, 2] = 'ZW'

    assert_equal 1, mapping[0]
    assert_equal "\x01XYZW56789abcdef".b, mapping[0...16]
    assert_equal 'XY', mapping.slice(1, 2)
  end

  def test_msync_accepts_only_valid_flag_combinations
    mapping = FakeFS::Mmap.new('file', 16, page_size: PAGE_SIZE)

    assert_equal 0, mapping.msync(FakeFS::Mmap::MS_ASYNC | FakeFS::Mmap::MS_INVALIDATE)
    error = assert_raises(FakeFS::Mmap::InvalidError) do
      mapping.msync(FakeFS::Mmap::MS_SYNC | FakeFS::Mmap::MS_ASYNC)
    end
    assert_equal 'MS_SYNC and MS_ASYNC cannot both be given', error.message
  end

  def test_truncate_keeps_mapping_length_but_invalidates_unbacked_pages
    mapping = FakeFS::Mmap.new('file', 32, page_size: PAGE_SIZE, prot: 'rw')

    File.truncate('file', 20)

    assert_equal 32, mapping.length
    assert_equal '0123456789abcdef0123', mapping.read(20)
    assert_raises(FakeFS::Mmap::BusError) { mapping.read(1, 20) }
    assert_raises(FakeFS::Mmap::BusError) { mapping.write('x', 20) }

    File.truncate('file', 32)
    assert_equal "\0\0\0\0\0\0\0\0\0\0\0\0".b, mapping.read(12, 20)
  end

  def test_io_truncate_keeps_existing_shared_mapping_connected
    File.open('file', 'r+') do |file|
      mapping = file.mmap(32, page_size: PAGE_SIZE, prot: 'rw')
      file.truncate(20)
      mapping.write('m', 0)
    end

    assert_equal "m#{File.binread('file', 19, 1)}", File.binread('file', 20)
  end

  def test_truncate_can_extend_with_zero_bytes_and_instance_returns_zero
    File.open('file', 'r+') do |file|
      assert_equal 0, file.truncate(40)
    end

    assert_equal 40, File.size('file')
    assert_equal "\0".b * 8, File.binread('file', 8, 32)
  end

  def test_cannot_map_a_closed_file
    file = File.open('file')
    file.close

    assert_raises(IOError) { file.mmap(16, page_size: PAGE_SIZE) }
  end

  def test_cross_page_private_write_and_read
    mapping = FakeFS::Mmap.new(
      'file', 32, page_size: PAGE_SIZE, flags: FakeFS::Mmap::MAP_PRIVATE, prot: 'rw'
    )

    mapping.write('COW-ACROSS-PAGES', 8)

    assert_equal 'COW-ACROSS-PAGES', mapping.read(16, 8)
    assert_equal '01234567', mapping.read(8)
    assert_equal '0123456789abcdef' * 2, File.binread('file')
  end

  def test_missing_file_and_out_of_mapping_access_raise
    assert_raises(Errno::ENOENT) do
      FakeFS::Mmap.new('missing', 16, page_size: PAGE_SIZE)
    end

    mapping = FakeFS::Mmap.new('file', 16, page_size: PAGE_SIZE)
    assert_raises(FakeFS::Mmap::BoundaryError) { mapping.read(1, 16) }
    assert_raises(FakeFS::Mmap::BoundaryError) { mapping.read(17) }
  end
end
