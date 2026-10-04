# frozen_string_literal: true

module FakeFS
  # Small, deterministic memory mapping simulation used by tests.
  class Mmap
    PROT_NONE  = 0
    PROT_READ  = 1
    PROT_WRITE = 2
    PROT_EXEC  = 4

    MAP_SHARED  = 1
    MAP_PRIVATE = 2

    MS_ASYNC      = 1
    MS_SYNC       = 4
    MS_INVALIDATE = 2

    class BusError < SignalException
      def initialize
        super('BUS')
      end
    end

    class SegmentationFault < SignalException
      def initialize
        super('SEGV')
      end
    end

    attr_reader :file, :length, :offset, :prot, :flags, :page_size

    def self.mmap(length, prot, flags, file, offset = 0, page_size: 4096)
      new(file, length, offset: offset, prot: prot, flags: flags, page_size: page_size)
    end

    def initialize(file, length, offset: 0, prot: PROT_READ, flags: MAP_PRIVATE, page_size: 4096)
      @file = resolve_file(file)
      @length = validate_nonnegative_integer(length, :length)
      @offset = validate_nonnegative_integer(offset, :offset)
      @prot = validate_prot(prot)
      @flags = validate_flags(flags)
      @page_size = validate_positive_integer(page_size, :page_size)

      raise ArgumentError, 'length must be greater than zero' if @length.zero?
      raise Errno::EINVAL, 'offset must be page aligned' unless aligned?(@offset)

      check_file_permissions!
      raise Errno::ENODEV, file.to_s if file.is_a?(FakeDir)
      @private_pages = {}
      @unmapped = false
    end

    def [](index, length = nil)
      ensure_active!

      if index.is_a?(Range)
        range = index
        start = range.begin
        start += @length if start.negative?
        finish = range.end
        finish += @length if finish.negative?
        finish -= 1 if range.exclude_end?
        return ''.b if finish < start

        read_bytes(start, finish - start + 1)
      else
        index = validate_nonnegative_integer(index, :index)
        length ? read_bytes(index, validate_length(length)) : read_byte(index)
      end
    end

    def []=(index, value)
      ensure_active!
      ensure_writable!

      if index.is_a?(Range)
        range = index
        start = range.begin
        start += @length if start.negative?
        data = byte_string(value)
        finish = range.end
        finish += @length if finish.negative?
        finish -= 1 if range.exclude_end?
        finish = start + data.bytesize - 1 if range.end.nil?
        raise RangeError, 'length mismatch' unless finish - start + 1 == data.bytesize

        write_bytes(start, data)
      else
        index = validate_nonnegative_integer(index, :index)
        if value.is_a?(String)
          write_bytes(index, value.b)
        else
          write_byte(index, value)
        end
      end
    end

    def getbyte(index)
      self[index]
    end

    def setbyte(index, value)
      self[index] = value.to_int & 0xff
      value.to_int
    end

    def read(length = @length, offset = 0)
      read_bytes(offset, length)
    end

    def write(data, offset = 0)
      write_bytes(offset, byte_string(data))
      data.bytesize
    end

    def to_s
      read
    end

    alias to_str to_s

    def mprotect(prot)
      ensure_active!
      @prot = validate_prot(prot)
      0
    end

    alias protect mprotect

    def msync(flags = MS_SYNC)
      ensure_active!
      valid_flags = [MS_ASYNC, MS_SYNC, MS_ASYNC | MS_INVALIDATE, MS_SYNC | MS_INVALIDATE]
      raise Errno::EINVAL, 'invalid msync flags' unless valid_flags.include?(flags)

      0
    end

    alias sync msync

    def munmap
      ensure_active!
      @private_pages.clear
      @unmapped = true
      0
    end

    alias unmap munmap

    def unmapped?
      @unmapped
    end

    def shared?
      flags == MAP_SHARED
    end

    def private?
      flags == MAP_PRIVATE
    end

    def readable?
      (prot & PROT_READ) != 0
    end

    def writable?
      (prot & PROT_WRITE) != 0
    end

    private

    def resolve_file(file)
      fake_file = file.instance_variable_get(:@file) if file.is_a?(FakeFS::File)
      fake_file ||= resolve_path(file.to_path) if file.respond_to?(:to_path)
      fake_file ||= resolve_path(file.to_s)
      fake_file
    end

    def resolve_path(path)
      resolved = FileSystem.find(path)
      raise Errno::ENOENT, path.to_s unless resolved

      if resolved.is_a?(FakeSymlink)
        target = resolved.entry
        raise Errno::ENOENT, path.to_s unless target

        resolve_path(target.to_s)
      else
        resolved
      end
    end

    def read_bytes(index, requested_length)
      ensure_readable!
      requested_length = validate_length(requested_length)
      check_mapping_bounds!(index, requested_length)

      bytes = +''.b
      requested_length.times do |position|
        bytes << mapped_byte(index + position)
      end
      bytes
    end

    def read_byte(index)
      ensure_readable!
      check_mapping_bounds!(index, 1)
      mapped_byte(index)
    end

    def write_bytes(index, data)
      ensure_writable!
      check_mapping_bounds!(index, data.bytesize)

      data.each_byte.with_index(index) do |byte, position|
        write_mapped_byte(position, byte)
      end
      data.bytesize
    end

    def write_byte(index, value)
      ensure_writable!
      check_mapping_bounds!(index, 1)
      write_mapped_byte(index, value.to_int & 0xff)
    end

    def mapped_byte(position)
      check_file_backing!(position)
      page = page_for_read(page_number(position))
      page.getbyte(page_offset(position)) || 0
    end

    def write_mapped_byte(position, byte)
      check_file_backing!(position)
      if shared?
        inode.write_mapped_byte(offset + position, byte)
      else
        page = page_for_write(page_number(position))
        page.setbyte(page_offset(position), byte)
      end
    end

    def page_for_read(number)
      @private_pages.fetch(number) { inode.mapped_page(number, page_size) }
    end

    def page_for_write(number)
      @private_pages[number] ||= inode.mapped_page(number, page_size).dup
    end

    def inode
      file.inode
    end

    def page_number(position)
      (offset + position).div(page_size)
    end

    def page_offset(position)
      (offset + position) % page_size
    end

    def check_mapping_bounds!(index, length = 1)
      raise RangeError, 'index outside mapping' if index.negative? || index >= @length
      return unless index + length > @length

      raise RangeError, 'access extends beyond mapping'
    end

    def check_file_backing!(position)
      return if offset + position < file.content.bytesize

      raise BusError
    end

    def ensure_active!
      raise IOError, 'memory mapping was unmapped' if @unmapped
    end

    def ensure_readable!
      raise SegmentationFault unless readable?
    end

    def ensure_writable!
      raise SegmentationFault unless writable?
    end

    def aligned?(value)
      value % page_size == 0
    end

    def validate_flags(value)
      value = value.to_int
      unless [MAP_SHARED, MAP_PRIVATE].include?(value)
        raise Errno::EINVAL, 'flags must include MAP_SHARED or MAP_PRIVATE'
      end
      value
    end

    def validate_prot(value)
      value = value.to_int
      if value & ~(PROT_READ | PROT_WRITE | PROT_EXEC) != 0
        raise Errno::EINVAL, 'invalid protection flags'
      end
      value
    end

    def validate_nonnegative_integer(value, name)
      value = value.to_int
      raise ArgumentError, "#{name} cannot be negative" if value.negative?
      value
    end

    def validate_positive_integer(value, name)
      value = value.to_int
      raise ArgumentError, "#{name} must be greater than zero" unless value.positive?
      value
    end

    def validate_length(value)
      validate_nonnegative_integer(value, :length)
    end

    def check_file_permissions!
      mode = file.mode & 0o777
      raise Errno::EACCES, 'file is not readable' if readable? && mode & 0o444 == 0
      raise Errno::EACCES, 'file is not writable' if writable? && mode & 0o222 == 0
    end

    def byte_string(value)
      return value.to_str.dup.force_encoding(Encoding::BINARY) if value.respond_to?(:to_str)

      Array(value).map { |item| item.to_int & 0xff }.pack('C*')
    end
  end

  MemoryMap = Mmap
  File::Mmap = Mmap
  File::MemoryMap = MemoryMap
end
