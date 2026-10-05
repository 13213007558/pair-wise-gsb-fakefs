# frozen_string_literal: true

require_relative '../test_helper'

class FileFcntlTest < Minitest::Test
  include FakeFS

  def setup
    FileSystem.clear
    File.write('file', '0123456789')
  end

  def test_flock_struct_has_native_field_shape
    byte_lock = File::Flock.new(Fcntl::F_WRLCK, 1, 2, IO::SEEK_SET, 3)

    assert_equal [Fcntl::F_WRLCK, 1, 2, IO::SEEK_SET, 3], byte_lock.to_a
  end

  def test_virtual_process_context_does_not_use_runner_pid
    assert_equal 0, ProcessContext.current_id

    ProcessContext.with(7) do
      assert_equal 7, ProcessContext.current_id
      ProcessContext.with(9) do
        assert_equal 9, ProcessContext.current_id
      end
      assert_equal 7, ProcessContext.current_id
    end

    assert_equal 0, ProcessContext.current_id
  end

  def test_posix_locks_belong_to_virtual_process
    first_file = open_file
    second_file = ProcessContext.with(2) { open_file }

    assert_equal 0, first_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    assert_raises(Errno::EAGAIN) do
      second_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    end
  end

  def test_posix_locks_ignore_descriptors_in_the_same_virtual_process
    first_file = open_file
    duplicated_file = first_file.dup
    independently_opened_file = open_file

    assert_equal 0, first_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    assert_equal 0, duplicated_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    assert_equal 0, independently_opened_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))

    duplicated_file.close
    independently_opened_file.close
  end

  def test_read_locks_are_shared_between_virtual_processes
    first_file = open_file
    second_file = ProcessContext.with(2) { open_file }

    assert_equal 0, first_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_RDLCK, 0, 10))
    assert_equal 0, second_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_RDLCK, 0, 10))
  end

  def test_posix_locks_are_released_when_any_descriptor_in_process_closes
    first_file = open_file
    duplicated_file = first_file.dup
    second_file = ProcessContext.with(2) { open_file }

    first_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    first_file.close

    assert_equal 0, second_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    duplicated_file.close
  end

  def test_duplicated_descriptors_share_an_open_file_description
    first_file = open_file
    duplicated_file = first_file.dup
    second_open_file = open_file

    first_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    duplicated_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    assert_raises(Errno::EAGAIN) do
      second_open_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    end

    first_file.close
    assert_raises(Errno::EAGAIN) do
      second_open_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    end

    duplicated_file.close
    assert_equal 0, second_open_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
  end

  def test_independent_opens_keep_open_file_description_locks_separate_across_processes
    first_file = ProcessContext.with(1) { open_file }
    second_file = ProcessContext.with(2) { open_file }

    first_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    assert_raises(Errno::EAGAIN) do
      second_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    end

    first_file.close
    assert_equal 0, second_file.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
  end

  def test_partial_unlock_splits_a_range
    file = open_file
    owner = [:process, 0]

    file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))
    file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_UNLCK, 3, 4))

    assert_equal(
      [{ type: Fcntl::F_WRLCK, start: 0, length: 3 },
       { type: Fcntl::F_WRLCK, start: 7, length: 3 }],
      lock_table.locks_for(owner)
    )
  end

  def test_repeated_locks_merge_overlapping_and_adjacent_ranges
    file = open_file
    owner = [:process, 0]

    file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_RDLCK, 2, 2))
    file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_RDLCK, 6, 2))
    file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_RDLCK, 4, 2))
    file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_RDLCK, 8, 2))

    assert_equal(
      [{ type: Fcntl::F_RDLCK, start: 2, length: 8 }],
      lock_table.locks_for(owner)
    )
  end

  def test_negative_length_is_normalized_and_zero_length_extends_forever
    holder = open_file
    waiter_file = ProcessContext.with(2) { File.open('file', 'r+') }
    holder.seek(4)
    holder.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, -3, IO::SEEK_CUR))

    assert_raises(Errno::EAGAIN) do
      waiter_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 1, 3))
    end

    holder.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_UNLCK, 0, 0))
    holder.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 5, 0))

    assert_raises(Errno::EAGAIN) do
      waiter_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 100, 1))
    end
  end

  def test_write_lock_requires_a_writable_descriptor
    read_only_file = File.open('file', 'r')

    assert_raises(Errno::EBADF) do
      read_only_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 1))
    end
  end

  def test_getlk_reports_conflicting_owner_or_unlocked
    first_file = open_file
    second_file = ProcessContext.with(2) { open_file }
    first_file.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 2, 3))

    conflict = lock(Fcntl::F_WRLCK, 0, 10)
    assert_equal 0, second_file.fcntl(Fcntl::F_GETLK, conflict)
    assert_equal Fcntl::F_WRLCK, conflict.l_type
    assert_equal 2, conflict.l_start
    assert_equal 3, conflict.l_len
    assert_equal 0, conflict.l_pid

    unlocked = lock(Fcntl::F_WRLCK, 20, 1)
    assert_equal 0, second_file.fcntl(Fcntl::F_GETLK, unlocked)
    assert_equal Fcntl::F_UNLCK, unlocked.l_type

    ofd_holder = open_file
    ofd_holder.fcntl(File::F_OFD_SETLK, lock(Fcntl::F_WRLCK, 20, 1))
    ofd_query = lock(Fcntl::F_WRLCK, 20, 1)
    second_file.fcntl(File::F_OFD_GETLK, ofd_query)
    assert_equal(-1, ofd_query.l_pid)
    ofd_holder.close
  end

  def test_waiting_lock_advances_only_when_scheduler_runs
    holder = open_file
    waiter_file = ProcessContext.with(2) { open_file }
    holder.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))

    scheduler = LockScheduler.new
    waiter = scheduler.run do
      waiter_file.fcntl(Fcntl::F_SETLKW, lock(Fcntl::F_WRLCK, 0, 10))
    end

    assert scheduler.waiting?
    assert_equal 1, scheduler.waiter_count
    assert waiter.alive?

    holder.close
    assert scheduler.waiting?
    assert scheduler.advance
    refute waiter.alive?
    refute scheduler.waiting?
  end

  def test_scheduler_advances_waiters_one_at_a_time
    holder = open_file
    first_waiter_file = ProcessContext.with(2) { File.open('file', 'r+') }
    second_waiter_file = ProcessContext.with(3) { File.open('file', 'r+') }
    holder.fcntl(Fcntl::F_SETLK, lock(Fcntl::F_WRLCK, 0, 10))

    scheduler = LockScheduler.new
    first_waiter = scheduler.run do
      first_waiter_file.fcntl(Fcntl::F_SETLKW, lock(Fcntl::F_WRLCK, 0, 10))
    end
    second_waiter = scheduler.run do
      second_waiter_file.fcntl(Fcntl::F_SETLKW, lock(Fcntl::F_WRLCK, 0, 10))
    end

    assert_equal 2, scheduler.waiter_count
    holder.close
    assert scheduler.advance
    refute first_waiter.alive?
    assert second_waiter.alive?

    first_waiter_file.close
    assert scheduler.advance
    refute second_waiter.alive?
  end

  private

  def open_file
    File.open('file', 'r+')
  end

  def lock(type, start, length, whence = IO::SEEK_SET)
    ByteRangeLock.new(type, start, length, whence, 0)
  end

  def lock_table
    FileSystem.find('file').inode.byte_range_locks
  end
end
