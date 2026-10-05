# frozen_string_literal: true

module FakeFS
  # Simulates a kernel open file description: the open-file state shared
  # by descriptors created with dup(2), while each independent open(2)
  # gets its own. Open file description locks (F_OFD_SETLK & friends)
  # belong to it and are released only when its last descriptor closes.
  class OpenFileDescription
    attr_reader :inode

    def initialize(inode)
      @inode = inode
      @references = 1
    end

    def retain
      @references += 1
      self
    end

    def release
      @references -= 1
      RecordLocking.release_ofd_locks(@inode, self) if @references.zero?
      self
    end
  end
end
