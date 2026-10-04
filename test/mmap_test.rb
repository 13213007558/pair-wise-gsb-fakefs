# frozen_string_literal: true

require_relative 'test_helper'

class MmapTest < Minitest::Test
  PAGE_SIZE = 4

  def setup
    FakeFS.activate!
    FakeFS::FileSystem.clear
    File.write('/mapped', 'abcdefgh')
  end

  def teardown
    FakeFS.deactivate!
    FakeFS::FileSystem.clear
  end

  def test_shared_mapping_and_file_io_share_pages
    mapping = mmap(8, flags: FakeFS::Mmap::MAP_SHARED,
                      prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    mapping[0] = 'X'
    assert_equal 'Xbcdefgh', File.read('/mapped')

    File.open('/mapped', 'r+') do |file|
      file.seek(1)
      file.write('Y')
    end

    assert_equal 'XYcdefgh', mapping.read
  end

  def test_shared_mapping_uses_the_inode_shared_by_hard_links
    File.link('/mapped', '/linked')
    mapping = mmap(4, flags: FakeFS::Mmap::MAP_SHARED,
                      prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    mapping[0] = 'X'

    assert_equal 'Xbcd', File.read('/linked', 4)
  end

  def test_private_mapping_uses_copy_on_write
    mapping = mmap(8, flags: FakeFS::Mmap::MAP_PRIVATE,
                      prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    mapping[0] = 'X'
    mapping.write('YY', 2)

    assert_equal 'XbYYefgh', mapping.read
    assert_equal 'abcdefgh', File.read('/mapped')

    assert_equal 0, mapping.msync(FakeFS::Mmap::MS_ASYNC)
    assert_equal 'abcdefgh', File.read('/mapped')
    assert_equal 0, mapping.msync(FakeFS::Mmap::MS_SYNC)
    assert_equal 'abcdefgh', File.read('/mapped')
  end

  def test_private_mapping_copies_by_page
    mapping = mmap(8, flags: FakeFS::Mmap::MAP_PRIVATE,
                      prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    mapping[0] = 'X'

    assert_equal 'X'.ord, mapping[0]
    assert_equal 'a', File.binread('/mapped', 1)
    File.binwrite('/mapped', 'Z', 1)

    assert_equal 'Xbcd', mapping.read(4)
    assert_equal 'aZcdefgh', File.read('/mapped')
    assert_equal 'efgh', mapping.read(4, 4)
  end

  def test_mapping_supports_aligned_offsets
    mapping = mmap(4, offset: PAGE_SIZE, flags: FakeFS::Mmap::MAP_SHARED,
                             prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    assert_equal 'efgh', mapping.read

    mapping[3] = 'Z'
    assert_equal 'abcdefgZ', File.read('/mapped')

    assert_raises(Errno::EINVAL) do
      mmap(4, offset: 1)
    end
  end

  def test_read_and_write_protection
    read_only = mmap(4, flags: FakeFS::Mmap::MAP_PRIVATE, prot: FakeFS::Mmap::PROT_READ)

    assert_equal 'abcd', read_only.read

    write_only = mmap(4, prot: FakeFS::Mmap::PROT_WRITE, flags: FakeFS::Mmap::MAP_SHARED)
    assert_raises(FakeFS::Mmap::SegmentationFault) do
      write_only[0]
    end

    File.chmod(0o444, '/mapped')
    assert_raises(Errno::EACCES) do
      mmap(4, prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)
    end

    assert_raises(FakeFS::Mmap::SegmentationFault) do
      read_only[0] = 'X'
    end

    assert_equal 0, read_only.mprotect(FakeFS::Mmap::PROT_NONE)
    assert_raises(FakeFS::Mmap::SegmentationFault) do
      read_only[0]
    end
  end

  def test_truncation_keeps_mapping_length_but_revokes_file_backing
    mapping = mmap(8, offset: 0, flags: FakeFS::Mmap::MAP_PRIVATE,
                             prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    File.truncate('/mapped', 5)

    assert_equal 8, mapping.length
    assert_equal 'abcde', mapping.read(5)
    assert_raises(FakeFS::Mmap::BusError) do
      mapping[5]
    end
    assert_raises(FakeFS::Mmap::BusError) do
      mapping.write('X', 5)
    end
  end

  def test_extending_a_file_fills_newly_backed_mapped_bytes_with_zeros
    mapping = mmap(8, flags: FakeFS::Mmap::MAP_SHARED, prot: FakeFS::Mmap::PROT_READ)

    File.truncate('/mapped', 4)
    File.truncate('/mapped', 6)

    assert_equal "abcd\x00\x00", mapping.read(6)
    assert_raises(FakeFS::Mmap::BusError) do
      mapping[6]
    end
  end

  def test_unmap_removes_private_changes_and_disables_access
    mapping = mmap(8, flags: FakeFS::Mmap::MAP_PRIVATE,
                      prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE)

    mapping.write('XXXXXXXX')
    assert_equal 0, mapping.munmap
    assert mapping.unmapped?
    assert_equal 'abcdefgh', File.read('/mapped')

    assert_raises(IOError) do
      mapping[0]
    end
  end

  def test_positional_constructor
    File.open('/mapped', 'r') do |file|
      mapping = FakeFS::Mmap.mmap(
        4,
        FakeFS::Mmap::PROT_READ,
        FakeFS::Mmap::MAP_SHARED,
        file,
        0,
        page_size: PAGE_SIZE
      )

      assert_equal 'abcd', mapping.read
    end
  end

  def test_file_object_constructor
    File.open('/mapped', 'r+') do |file|
      mapping = file.mmap(4, page_size: PAGE_SIZE,
                             prot: FakeFS::Mmap::PROT_READ | FakeFS::Mmap::PROT_WRITE,
                             flags: FakeFS::Mmap::MAP_SHARED)

      mapping.write('Z')
    end

    assert_equal 'Zbcdefgh', File.read('/mapped')
    assert_equal 0, File.truncate('/mapped', 4)
    assert_equal 'Zbcd', File.read('/mapped')
  end

  def test_path_resolves_symlinks
    File.symlink('mapped', '/link')

    mapping = mmap(4)

    assert_equal 'abcd', mapping.read
    assert_equal '/mapped', mapping.file.to_s
  end

  private

  def mmap(length, **options)
    FakeFS::Mmap.new('/mapped', length, **options, page_size: PAGE_SIZE)
  end
end
