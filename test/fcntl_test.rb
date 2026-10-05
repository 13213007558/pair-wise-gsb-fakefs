# frozen_string_literal: true

require_relative 'test_helper'

# Tests for fcntl(2) byte-range record locks: POSIX process locks
# (F_SETLK/F_SETLKW/F_GETLK) and open file description locks
# (F_OFD_SETLK/F_OFD_SETLKW/F_OFD_GETLK).
class FcntlTest < Minitest::Test
  F_GETLK = FakeFS::File::F_GETLK
  F_SETLK = FakeFS::File::F_SETLK
  F_SETLKW = FakeFS::File::F_SETLKW
  F_OFD_GETLK = FakeFS::File::F_OFD_GETLK
  F_OFD_SETLK = FakeFS::File::F_OFD_SETLK
  F_OFD_SETLKW = FakeFS::File::F_OFD_SETLKW
  F_RDLCK = FakeFS::File::F_RDLCK
  F_WRLCK = FakeFS::File::F_WRLCK
  F_UNLCK = FakeFS::File::F_UNLCK
  SEEK_SET = FakeFS::File::SEEK_SET

  def setup
    FakeFS.activate!
    FakeFS::FileSystem.clear
    FakeFS::File.write('/locked', 'x' * 100)
  end

  def teardown
    FakeFS.deactivate!
    FakeFS::FileSystem.clear
  end

  def open_file(mode = 'r+')
    FakeFS::File.open('/locked', mode)
  end

  def lock(file, command, type, first, len)
    file.fcntl(command, [type, SEEK_SET, first, len])
  end

  def get_lock(file, command, type, first, len)
    request = [type, SEEK_SET, first, len]
    file.fcntl(command, request)
    request
  end

  def held_locks
    inode = FakeFS::FileSystem.find('/locked').inode
    FakeFS::RecordLocking.locks_for(inode).map do |lock|
      owner = lock.owner
      subject = owner.kind == :process ? owner.subject.pid : :ofd
      [owner.kind, subject, lock.type, lock.first, lock.last]
    end
  end

  def test_virtual_process_context_is_explicit_and_not_the_real_pid
    refute_equal Process.pid, FakeFS::VirtualProcess.current.pid
    assert_equal FakeFS::VirtualProcess::DEFAULT_PID, FakeFS::VirtualProcess.current.pid

    FakeFS::VirtualProcess.with(1001) do |process|
      assert_equal 1001, process.pid
      assert_same process, FakeFS::VirtualProcess.current
    end
    assert_equal FakeFS::VirtualProcess::DEFAULT_PID, FakeFS::VirtualProcess.current.pid

    FakeFS::VirtualProcess.current_pid = 1002
    assert_equal 1002, FakeFS::VirtualProcess.current.pid
    assert_same FakeFS::VirtualProcess[1002], FakeFS::VirtualProcess.current
  end

  def test_posix_locks_conflict_between_virtual_processes
    file = open_file
    FakeFS::VirtualProcess.with(1001) do
      assert_equal 0, lock(file, F_SETLK, F_WRLCK, 0, 10)
    end

    FakeFS::VirtualProcess.with(1002) do
      assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 5, 10) }
      assert_equal 0, lock(file, F_SETLK, F_WRLCK, 10, 10) # adjacent ranges do not conflict
      assert_equal [F_WRLCK, SEEK_SET, 0, 10, 1001], get_lock(file, F_GETLK, F_WRLCK, 0, 10)
      assert_equal [F_UNLCK, SEEK_SET, 50, 10, 0], get_lock(file, F_GETLK, F_WRLCK, 50, 10)
    end
  end

  def test_posix_locks_do_not_conflict_within_the_same_process
    file = open_file
    other = open_file
    FakeFS::VirtualProcess.with(1001) do
      lock(file, F_SETLK, F_WRLCK, 0, 10)
      assert_equal 0, lock(other, F_SETLK, F_WRLCK, 5, 10) # same process, independent open
    end
    assert_equal [[:process, 1001, :write, 0, 15]], held_locks
  end

  def test_read_locks_are_shared_but_conflict_with_write_locks
    file = open_file
    FakeFS::VirtualProcess.with(1001) { lock(file, F_SETLK, F_RDLCK, 0, 10) }

    FakeFS::VirtualProcess.with(1002) do
      assert_equal 0, lock(file, F_SETLK, F_RDLCK, 0, 10)
      assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 0, 10) }
    end
  end

  def test_partial_unlock_splits_a_range_in_two
    file = open_file
    FakeFS::VirtualProcess.with(1001) do
      lock(file, F_SETLK, F_WRLCK, 0, 10)
      assert_equal 0, lock(file, F_SETLK, F_UNLCK, 3, 4)
    end
    assert_equal [[:process, 1001, :write, 0, 3], [:process, 1001, :write, 7, 10]], held_locks

    FakeFS::VirtualProcess.with(1002) do
      assert_equal 0, lock(file, F_SETLK, F_WRLCK, 3, 4) # the hole is free
      assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 2, 1) }
      assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 8, 1) }
    end
  end

  def test_relocking_merges_adjacent_and_overlapping_ranges
    file = open_file
    FakeFS::VirtualProcess.with(1001) do
      lock(file, F_SETLK, F_WRLCK, 0, 5)
      lock(file, F_SETLK, F_WRLCK, 10, 5)
      assert_equal [[:process, 1001, :write, 0, 5], [:process, 1001, :write, 10, 15]], held_locks

      lock(file, F_SETLK, F_WRLCK, 5, 5) # bridges the gap
      assert_equal [[:process, 1001, :write, 0, 15]], held_locks

      lock(file, F_SETLK, F_WRLCK, 3, 4) # re-locking a sub-range keeps one segment
      assert_equal [[:process, 1001, :write, 0, 15]], held_locks

      lock(file, F_SETLK, F_UNLCK, 0, 15)
      assert_equal [], held_locks
    end
  end

  def test_unlock_outside_held_ranges_is_a_no_op
    file = open_file
    FakeFS::VirtualProcess.with(1001) do
      assert_equal 0, lock(file, F_SETLK, F_UNLCK, 0, 100)
      lock(file, F_SETLK, F_WRLCK, 0, 10)
      assert_equal 0, lock(file, F_SETLK, F_UNLCK, 50, 10)
      assert_equal [[:process, 1001, :write, 0, 10]], held_locks
    end
  end

  def test_lock_to_end_of_file_and_relative_ranges
    file = open_file
    FakeFS::VirtualProcess.with(1001) do
      lock(file, F_SETLK, F_WRLCK, 90, 0) # l_len 0 locks to end of file
    end
    assert_equal [[:process, 1001, :write, 90, Float::INFINITY]], held_locks

    FakeFS::VirtualProcess.with(1002) do
      # the conflicting lock is reported with l_len 0 for "to end of file"
      assert_equal [F_WRLCK, SEEK_SET, 90, 0, 1001], get_lock(file, F_GETLK, F_WRLCK, 95, 5)
    end

    file.fcntl(F_SETLK, [F_WRLCK, FakeFS::File::SEEK_END, -20, 10])
    file.seek(5)
    file.fcntl(F_SETLK, [F_WRLCK, FakeFS::File::SEEK_CUR, 0, 5])
    assert_equal [[:process, 1, :write, 5, 10], [:process, 1, :write, 80, 90],
                  [:process, 1001, :write, 90, Float::INFINITY]], held_locks
  end

  def test_dup_shares_the_open_file_description
    file = open_file
    duplicate = file.dup
    lock(file, F_OFD_SETLK, F_WRLCK, 0, 10)

    # the same description never conflicts with itself
    assert_equal F_UNLCK, get_lock(duplicate, F_OFD_GETLK, F_WRLCK, 0, 10)[0]
    assert_equal 0, lock(duplicate, F_OFD_SETLK, F_WRLCK, 0, 10)
    assert_equal [[:ofd, :ofd, :write, 0, 10]], held_locks

    # ...but POSIX locks of another virtual process still conflict with it
    FakeFS::VirtualProcess.with(1002) do
      assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 0, 10) }
    end
  end

  def test_independent_opens_have_distinct_open_file_descriptions
    file = open_file
    other = open_file
    lock(file, F_OFD_SETLK, F_WRLCK, 0, 10)

    # even within the same virtual process, a second open() is another owner
    assert_raises(Errno::EAGAIN) { lock(other, F_OFD_SETLK, F_WRLCK, 5, 5) }
    # OFD locks are not attributed to a process, so l_pid is reported as -1
    assert_equal [F_WRLCK, SEEK_SET, 0, 10, -1], get_lock(other, F_OFD_GETLK, F_WRLCK, 5, 5)

    # POSIX locks belong to the process instead and do not conflict here
    lock(file, F_SETLK, F_WRLCK, 20, 10)
    assert_equal 0, lock(other, F_SETLK, F_WRLCK, 25, 5)
  end

  def test_ofd_locks_survive_until_the_last_dup_closes
    file = open_file
    duplicate = file.dup
    lock(file, F_OFD_SETLK, F_WRLCK, 0, 10)

    file.close
    assert_equal [[:ofd, :ofd, :write, 0, 10]], held_locks
    FakeFS::VirtualProcess.with(1002) do
      assert_raises(Errno::EAGAIN) { lock(open_file, F_OFD_SETLK, F_WRLCK, 0, 10) }
    end

    duplicate.close
    assert_equal [], held_locks
    assert_equal 0, lock(open_file, F_OFD_SETLK, F_WRLCK, 0, 10)
  end

  def test_posix_locks_are_released_when_the_process_closes_any_descriptor
    file = open_file
    other = open_file
    FakeFS::VirtualProcess.with(1001) do
      lock(file, F_SETLK, F_WRLCK, 0, 10)
      other.close # POSIX gotcha: closing *any* fd for the file drops the locks
    end
    assert_equal [], held_locks
    FakeFS::VirtualProcess.with(1002) do
      assert_equal 0, lock(file, F_SETLK, F_WRLCK, 0, 10)
    end
  end

  def test_closing_a_descriptor_of_another_process_keeps_its_locks
    file = open_file
    FakeFS::VirtualProcess.with(1001) { lock(file, F_SETLK, F_WRLCK, 0, 10) }
    FakeFS::VirtualProcess.with(1002) do
      open_file.close
      assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 0, 10) }
    end
    assert_equal [[:process, 1001, :write, 0, 10]], held_locks
  end

  def test_blocking_setlkw_is_advanced_by_the_controlled_scheduler
    scheduler = FakeFS::RecordLocking::ControlledScheduler.new
    FakeFS::RecordLocking.scheduler = scheduler
    file = open_file
    FakeFS::VirtualProcess.current_pid = 1001
    lock(file, F_SETLK, F_WRLCK, 0, 10)

    events = []
    waiter = Fiber.new do
      FakeFS::VirtualProcess.with(1002) do
        lock(file, F_SETLKW, F_WRLCK, 0, 10)
      end
      events << :acquired
    end
    waiter.resume
    assert_equal 1, scheduler.waiters.size
    assert_empty events

    # the lock is still held, so the parked waiter cannot make progress
    FakeFS::VirtualProcess.current_pid = 1001
    assert_raises(FakeFS::RecordLocking::DeadlockError) { scheduler.drain }
    assert_empty events

    lock(file, F_SETLK, F_UNLCK, 0, 10)
    scheduler.drain
    assert_equal [:acquired], events
    assert_equal [[:process, 1002, :write, 0, 10]], held_locks
    assert_raises(Errno::EAGAIN) { lock(file, F_SETLK, F_WRLCK, 0, 10) }
  end

  def test_blocking_ofd_lock_is_released_by_close_and_advanced_by_the_scheduler
    scheduler = FakeFS::RecordLocking::ControlledScheduler.new
    FakeFS::RecordLocking.scheduler = scheduler
    file = open_file
    other = open_file
    lock(file, F_OFD_SETLK, F_WRLCK, 0, 10)

    events = []
    waiter = Fiber.new do
      lock(other, F_OFD_SETLKW, F_WRLCK, 0, 10)
      events << :acquired
    end
    waiter.resume
    assert_equal 1, scheduler.waiters.size

    duplicate = file.dup
    file.close
    # the dup'ed descriptor keeps the open file description (and its locks) alive
    assert_raises(FakeFS::RecordLocking::DeadlockError) { scheduler.drain }
    assert_empty events

    duplicate.close
    scheduler.drain
    assert_equal [:acquired], events
    assert_equal [[:ofd, :ofd, :write, 0, 10]], held_locks
  end

  def test_packed_struct_flock_string_is_updated_in_place
    file = open_file
    format = FakeFS::File::FLOCK_STRUCT_FORMAT
    FakeFS::VirtualProcess.with(1001) do
      assert_equal 0, file.fcntl(F_SETLK, [F_WRLCK, 0, 0, 10, 0].pack(format))
    end

    FakeFS::VirtualProcess.with(1002) do
      request = [F_WRLCK, 0, 0, 10, 0].pack(format)
      assert_equal 0, file.fcntl(F_GETLK, request)
      assert_equal [F_WRLCK, 0, 0, 10, 1001], request.unpack(format)

      free = [F_WRLCK, 0, 50, 10, 0].pack(format)
      file.fcntl(F_GETLK, free)
      assert_equal F_UNLCK, free.unpack(format)[0]
    end
  end

  def test_lock_commands_validate_their_arguments
    file = open_file
    assert_raises(TypeError) { file.fcntl(F_SETLK, 12) }
    assert_raises(Errno::EINVAL) { file.fcntl(F_SETLK, [99, 0, 0, 10]) }
    assert_raises(Errno::EINVAL) { file.fcntl(F_SETLK, [F_WRLCK, 0, -5, 10]) }
    assert_raises(Errno::EINVAL) { file.fcntl(F_SETLK, [F_WRLCK, 99, 0, 10]) }
    assert_raises(NotImplementedError) { file.fcntl(65_535, [F_WRLCK, 0, 0, 10]) }
    file.close
    assert_raises(IOError) { file.fcntl(F_GETLK, [F_WRLCK, 0, 0, 10]) }
  end

  def test_lock_type_must_match_the_descriptor_access_mode
    reader = open_file('r')
    assert_raises(Errno::EBADF) { lock(reader, F_SETLK, F_WRLCK, 0, 10) }
    assert_equal 0, lock(reader, F_SETLK, F_RDLCK, 0, 10)
    reader.close

    writer = open_file('w')
    assert_raises(Errno::EBADF) { lock(writer, F_SETLK, F_RDLCK, 0, 10) }
    assert_equal 0, lock(writer, F_SETLK, F_WRLCK, 0, 10)
    writer.close
  end

  def test_lock_state_is_reset_with_the_file_system
    file = open_file
    lock(file, F_SETLK, F_WRLCK, 0, 10)
    FakeFS::RecordLocking.scheduler = FakeFS::RecordLocking::ControlledScheduler.new
    FakeFS::VirtualProcess.current_pid = 1002

    FakeFS::FileSystem.clear
    FakeFS::File.write('/locked', 'x')

    assert_equal [], held_locks
    assert_equal FakeFS::VirtualProcess::DEFAULT_PID, FakeFS::VirtualProcess.current.pid
    assert_instance_of FakeFS::RecordLocking::ThreadScheduler, FakeFS::RecordLocking.scheduler
  end
end
