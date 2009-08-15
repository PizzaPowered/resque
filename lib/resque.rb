require 'redis'
require 'yajl'

require 'resque/job'
require 'resque/worker'

class Resque
  attr_reader :redis

  WORKER_TTL = 10_000 # How many seconds until expiration for worker-specific
                      # keys. Fake GC.

  def initialize(server)
    host, port = server.split(':')
    @redis = Redis.new(:host => host, :port => port)
  end

  def to_s
    "Resque Client connected to #{@redis.server}"
  end


  #
  # queue manipulation
  #

  def push(queue, item)
    watch_queue(queue)
    @redis.rpush(key(:queue, queue), encode(item))
  end

  def pop(queue)
    decode @redis.lpop(key(:queue, queue))
  end

  def size(queue)
    @redis.llen(key(:queue, queue))
  end

  def peek(queue, start = 0, count = 1)
    if count == 1
      decode @redis.lindex(key(:queue, queue), start)
    else
      Array(@redis.lrange(key(:queue, queue), start, start+count-1)).map do |item|
        decode item
      end
    end
  end

  def queues
    @redis.smembers(key(:queues))
  end

  def watch_queue(queue)
    @watched_queues ||= {}
    return if @watched_queues[queue]
    @redis.sadd(key(:queues), queue.to_s)
  end


  #
  # jobs.
  #

  def enqueue(queue, klass, *args)
    push(queue, :class => klass.to_s, :args => args)
  end

  def reserve(queue)
    return unless payload = pop(queue)
    Job.new(self, queue, payload)
  end


  #
  # workers
  #

  def add_worker(worker)
    @redis.pipelined do |redis|
      redis.sadd(key(:workers), worker.to_s)
      redis.set(key(:worker, worker.to_s, :started), Time.now.to_s)
      redis.expire(key(:worker, worker.to_s, :started), WORKER_TTL)
    end
  end

  def remove_worker(worker)
    clear_processed_for worker
    clear_failed_for worker
    @redis.del(key(:worker, worker.to_s, :started))
    @redis.srem(key(:workers), worker.to_s)
  end

  def workers
    @redis.smembers(key(:workers))
  end

  def worker(id)
    decode @redis.get(key(:worker, id.to_s))
  end

  def worker?(id)
    @redis.sismember(key(:workers), id.to_s)
  end

  def working
    names = workers
    return [] unless names.any?
    names = names.map { |name| key(:worker, name) }
    @redis.mapped_mget(*names).keys.map do |key|
      # cleanup
      key.sub(key(:worker) + ':', '')
    end
  end

  def worker_started(id)
    @redis.get(key(:worker, id.to_s, :started))
  end

  def worker_state(id)
    @redis.exists(key(:worker, id)) ? :working : :idle
  end

  def set_worker_status(id, queue, payload)
    data = encode \
      :queue   => queue,
      :run_at  => Time.now.to_s,
      :payload => payload
    target = key(:worker, id.to_s)
    @redis.pipelined do |redis|
      redis.set(target, data)
      redis.expire(target, WORKER_TTL)
    end
  end

  def clear_worker_status(id)
    @redis.del(key(:worker, id.to_s))
  end


  #
  # stats
  #

  def info
    return {
      :pending   => pending,
      :processed => processed,
      :queues    => queues.size,
      :workers   => workers.size.to_i,
      :working   => working.size,
      :failed    => failed,
      :servers   => [@redis.server]
    }
  end

  def pending
    queues.inject(0) { |m,k| m + size(k) }
  end

  # Called by workers when a job has been processed,
  # regardless of pass or fail.
  def processed!(id = nil)
    @redis.incr(key(:stats, :processed))
    if id
      target = key(:stats, :processed, id.to_s)
      @redis.pipelined do |redis|
        redis.incr(target)
        redis.expire(target, WORKER_TTL)
      end
    end
  end

  def processed(id = nil)
    target = id ? key(:stats, :processed, id.to_s) : key(:stats, :processed)
    @redis.get(target).to_i
  end

  def clear_processed_for(id)
    @redis.del key(:stats, :processed, id.to_s)
  end

  def failed!(id = nil)
    if id
      target = key(:stats, :failed, id.to_s)
      @redis.pipelined do |redis|
        redis.incr(target)
        redis.expire(target, WORKER_TTL)
      end
    end
  end

  def failed(id = nil)
    id ? @redis.get(key(:stats, :failed, id.to_s)).to_i : size(:failed).to_i
  end

  def clear_failed_for(id)
    @redis.del key(:stats, :failed, id.to_s)
  end


  #
  # encoding / decoding
  #

  def encode(object)
    Yajl::Encoder.encode(object)
  end

  def decode(object)
    Yajl::Parser.parse(object) if object
  end

  #
  # namespacing
  #

  def key(*queue)
    "resque:#{queue.join(':')}"
  end
end
