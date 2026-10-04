# frozen_string_literal: true

module FakeFS
  # A small deterministic, page-oriented mmap implementation for tests.
  class Mmap
    PROT_NONE  = 0
    PROT_READ  = 1
    PROT_WRITE = 2
    PROT_EXEC  = 4

    MAP_SHARED  = 1
    MAP_PRIVATE = 2

    MS_SYNC       = 1
    MS_ASYNC      = 2
    MS_INVALIDATE = 4

    DEFAULT_PAGE_SIZE = 4096

    class Error < StandardError; end
    class InvalidError < Error; end
    class PermissionError < Error; end
    class BoundaryError < Error; end

    # Simulates SIGBUS when touching a mapped byte that is not backed by the file.
    class BusError < Error; end

    class UnmappedError < Error; end

    attr_reader :length, :offset, :prot, :flags, :page_size

    def self.new(path_or_file, length = nil, third_argument = nil, positional_flags = nil,
                 positional_offset = nil, **positional_options)
      source = path_or_file
      if source.is_a?(FakeFS::File)
        file = source.instance_variable_get(:@file)
      else
        file = FileSystem.find(source)
      end

      raise Errno::ENOENT, source.to_s unless file
      raise InvalidError, 'cannot mmap a directory' if file.is_a?(FakeDir)

      options = build_options(third_argument, positional_flags, positional_offset, positional_options)

      page_size = integer_option(options, :page_size, DEFAULT_PAGE_SIZE)
      raise InvalidError, 'page size must be positive' unless page_size.positive?
      raise InvalidError, 'page size must be a power of two' unless power_of_two?(page_size)

      mapped_offset = integer_option(options, :offset, 0)
      raise InvalidError, 'offset must not be negative' if mapped_offset.negative?
      unless (mapped_offset % page_size).zero?
        raise InvalidError, 'offset must be page aligned'
      end

      mapped_length = length.nil? ? file.content.bytesize - mapped_offset : integer_value(length, 'length')
      raise InvalidError, 'length must be positive' unless mapped_length&.positive?

      protection = protection_value(options.fetch(:prot, PROT_READ))
      known_protection = PROT_READ | PROT_WRITE | PROT_EXEC
      raise InvalidError, 'invalid protection' unless (protection & ~known_protection).zero?

      mapping_flags = mapping_flags(options)

      allocate.tap do |mapping|
        mapping.send(
          :initialize_mapping,
          file, mapped_length, mapped_offset, protection, mapping_flags, page_size
        )
      end
    end

    def self.power_of_two?(value)
      value.positive? && (value & (value - 1)).zero?
    end
    private_class_method :power_of_two?

    def self.integer_option(options, key, default)
      return default unless options.key?(key)

      integer_value(options[key], key.to_s)
    end
    private_class_method :integer_option

    def self.integer_value(value, name)
      value = value.to_int if value.respond_to?(:to_int)
      raise TypeError, "#{name} must be an integer" unless value.is_a?(Integer)

      value
    end
    private_class_method :integer_value

    def self.build_options(third_argument, positional_flags, positional_offset, positional_options)
      options = positional_options.dup
      if third_argument.is_a?(Hash)
        third_argument.merge(options)
      else
        options[:prot] ||= third_argument unless third_argument.nil?
        options[:flags] ||= positional_flags unless positional_flags.nil?
        options[:offset] ||= positional_offset unless positional_offset.nil?
        options
      end
    end
    private_class_method :build_options

    def self.mapping_flags(options)
      if options.key?(:flags)
        flags = mapping_value(options[:flags])
      elsif options[:shared] == false || (options.key?(:private) && options[:private])
        flags = MAP_PRIVATE
      elsif options[:shared] == true || options[:type] == :shared || options[:type] == 'shared'
        flags = MAP_SHARED
      elsif options[:type] == :private || options[:type] == 'private'
        flags = MAP_PRIVATE
      else
        flags = MAP_SHARED
      end

      return flags if [MAP_SHARED, MAP_PRIVATE].include?(flags)

      raise InvalidError, 'flags must be MAP_SHARED or MAP_PRIVATE'
    end
    private_class_method :mapping_flags

    def self.mapping_value(value)
      case value
      when Integer
        value
      when :shared, 'shared' then MAP_SHARED
      when :private, 'private' then MAP_PRIVATE
      else
        raise TypeError, 'flags must be MAP_SHARED or MAP_PRIVATE'
      end
    end
    private_class_method :mapping_value

    def self.protection_value(value)
      case value
      when Integer
        value
      when Symbol, String
        case value.to_s
        when 'r', 'read' then PROT_READ
        when 'w', 'write' then PROT_WRITE
        when 'x', 'exec' then PROT_EXEC
        when 'rw', 'wr', 'read_write', 'rdwr'
          PROT_READ | PROT_WRITE
        else
          value.to_s.each_char.reduce(PROT_NONE) do |protection, character|
            case character
            when 'r' then protection | PROT_READ
            when 'w' then protection | PROT_WRITE
            when 'x' then protection | PROT_EXEC
            else raise InvalidError, "invalid protection: #{value.inspect}"
            end
          end
        end
      when Array
        value.reduce(PROT_NONE) { |protection, item| protection | protection_value(item) }
      else
        raise TypeError, 'prot must be an integer or protection string'
      end
    end
    private_class_method :protection_value

    def self.open(*args, **options, &block)
      mapping = new(*args, **options)
      return mapping unless block

      begin
        yield mapping
      ensure
        mapping.unmap if mapping.mapped?
      end
    end

    def shared?
      flags == MAP_SHARED
    end

    def private?
      flags == MAP_PRIVATE
    end

    def mapped?
      @mapped
    end

    def size
      length
    end

    def [](start, requested_length = nil)
      ensure_mapped!

      if start.is_a?(Range)
        range = start
        first = local_index(range.first)
        last = local_index(range.end)
        last -= 1 if range.exclude_end?
        raise BoundaryError, 'memory access outside mapping' if first.negative? || last >= length

        read_bytes(first, last - first + 1)
      elsif requested_length.nil?
        position = local_index(start)
        ensure_within_mapping!(position, 1)
        read_bytes(position, 1).ord
      else
        position = local_index(start)
        amount = integer_argument(requested_length, 'length')
        ensure_within_mapping!(position, amount)
        read_bytes(position, amount)
      end
    end

    alias slice []

    def []=(start, requested_length_or_value, value = nil)
      ensure_mapped!
      ensure_writable!

      if start.is_a?(Range)
        range = start
        first = local_index(range.first)
        last = local_index(range.end)
        last -= 1 if range.exclude_end?
        amount = last - first + 1
        data = requested_length_or_value
        ensure_write_allowed!(first, data, amount)
      elsif value.nil?
        position = local_index(start)
        data = requested_length_or_value
        if data.is_a?(Integer)
          ensure_write_allowed!(position, byte_value(data), 1)
        else
          ensure_write_allowed!(position, data, data.bytesize)
        end
      else
        position = local_index(start)
        amount = integer_argument(requested_length_or_value, 'length')
        ensure_write_allowed!(position, value, amount)
      end
    end

    def read(amount = length, position = 0)
      ensure_mapped!
      ensure_readable!
      amount = integer_argument(amount, 'length')
      position = integer_argument(position, 'offset')
      ensure_within_mapping!(position, amount)
      read_bytes(position, amount)
    end

    def write(data, position = 0)
      ensure_mapped!
      ensure_writable!
      position = integer_argument(position, 'offset')
      ensure_write_allowed!(position, data, data.bytesize)
      data.bytesize
    end

    def getbyte(position)
      self[position]
    end

    def setbyte(position, value)
      self[position] = integer_argument(value, 'byte')
      value
    end

    def to_s
      read
    end

    def msync(sync_flags = MS_SYNC)
      ensure_mapped!
      sync_flags = integer_argument(sync_flags, 'flags')
      known_flags = MS_SYNC | MS_ASYNC | MS_INVALIDATE
      raise InvalidError, 'invalid msync flags' unless (sync_flags & ~known_flags).zero?
      if (sync_flags & (MS_SYNC | MS_ASYNC)) == (MS_SYNC | MS_ASYNC)
        raise InvalidError, 'MS_SYNC and MS_ASYNC cannot both be given'
      end

      0
    end

    alias flush msync
    alias sync msync

    def unmap
      ensure_mapped!
      @private_pages.clear
      @mapped = false
      nil
    end

    alias close unmap
    alias munmap unmap

    private

    def initialize_mapping(file, mapped_length, mapped_offset, protection, mapping_flags, mapped_page_size)
      @file = file
      @length = mapped_length
      @offset = mapped_offset
      @prot = protection
      @flags = mapping_flags
      @page_size = mapped_page_size
      @private_pages = {}
      @mapped = true
    end

    def local_index(value)
      value = integer_argument(value, 'index')
      value += length if value.negative?
      value
    end

    def integer_argument(value, name)
      value = value.to_int if value.respond_to?(:to_int)
      raise TypeError, "#{name} must be an integer" unless value.is_a?(Integer)

      value
    end

    def ensure_mapped!
      raise UnmappedError, 'memory mapping has been unmapped' unless @mapped
    end

    def ensure_readable!
      return unless (prot & (PROT_READ | PROT_EXEC)).zero?

      raise PermissionError, 'memory mapping is not readable'
    end

    def ensure_writable!
      return unless (prot & PROT_WRITE).zero?

      raise PermissionError, 'memory mapping is not writable'
    end

    def ensure_within_mapping!(position, amount)
      raise InvalidError, 'length cannot be negative' if amount.negative?
      raise BoundaryError, 'memory access outside mapping' if position.negative?
      raise BoundaryError, 'memory access outside mapping' if position + amount > length
    end

    def ensure_file_backing!(position, amount)
      file_size = @file.content.bytesize
      absolute_position = offset + position
      return if amount.zero?
      return if absolute_position < file_size && absolute_position + amount <= file_size

      raise BusError, 'memory access outside file-backed range'
    end

    def ensure_write_allowed!(position, value, amount)
      ensure_within_mapping!(position, amount)
      ensure_file_backing!(position, amount)
      data = value.is_a?(Integer) ? byte_value(value).chr : value.to_str
      raise ArgumentError, 'wrong number of bytes written' unless data.bytesize == amount

      write_bytes(position, data.b)
    end

    def byte_value(value)
      value = integer_argument(value, 'byte')
      raise RangeError, 'byte must be between 0 and 255' unless value.between?(0, 255)

      value
    end

    def read_bytes(position, amount)
      ensure_readable!
      ensure_file_backing!(position, amount)
      return ''.b if amount.zero?
      return @file.content.byteslice(offset + position, amount).b unless private?

      read_private_bytes(position, amount)
    end

    def read_private_bytes(position, amount)
      result = ''.b
      each_page_range(position, amount) do |page_position, chunk|
        page = @private_pages[page_index(page_position)]
        unless page
          result << @file.content.byteslice(offset + page_position, chunk).b
          next
        end

        result << page.byteslice(page_position % page_size, chunk)
      end
      result
    end

    def write_bytes(position, data)
      if shared?
        replace_backing_bytes(position, data)
      else
        copy_pages(position, data.bytesize)
        replace_private_bytes(position, data)
      end
      @file.mtime = Time.now if shared?
    end

    def copy_pages(position, amount)
      return if amount.zero?

      start_page = page_index(position)
      end_page = page_index(position + amount - 1)
      start_page.upto(end_page) do |page_index|
        next if @private_pages.key?(page_index)

        absolute_start = offset + (page_index * page_size)
        available = [0, [@file.content.bytesize - absolute_start, page_size].min].max
        page = "\0".b * page_size
        page.bytesplice(0, available, @file.content.byteslice(absolute_start, available).b) if available.positive?
        @private_pages[page_index] = page
      end
    end

    def replace_private_bytes(position, data)
      data_start = 0
      each_page_range(position, data.bytesize) do |page_position, amount|
        page = @private_pages[page_index(page_position)]
        page.bytesplice(page_position % page_size, amount, data.byteslice(data_start, amount))
        data_start += amount
      end
    end

    def replace_backing_bytes(position, data)
      content = @file.content
      original_encoding = content.encoding
      content.force_encoding(Encoding::BINARY)
      content.bytesplice(offset + position, data.bytesize, data)
    ensure
      content.force_encoding(original_encoding)
    end

    def each_page_range(position, amount)
      remaining = amount
      current = position
      while remaining.positive?
        page_offset = current % page_size
        chunk = [page_size - page_offset, remaining].min
        yield(current, chunk)
        current += chunk
        remaining -= chunk
      end
    end

    def page_index(position)
      (offset + position) / page_size
    end
  end

  MemoryMap = Mmap
  MMap = Mmap
end
