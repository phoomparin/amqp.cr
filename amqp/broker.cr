require "socket"
require "./protocol"
require "./spec091"
require "./timed_channel"

class AMQP::Broker
  ProtocolHeader = ['A'.ord, 'M'.ord, 'Q'.ord, 'P'.ord, 0, 0, 9, 1].map(&.to_u8)

  getter closed

  def initialize(@config)
    @socket = TCPSocket.new(@config.host, @config.port)
    @io = Protocol::IO.new(@socket)
    @sends = ::Channel(Time).new(1)
    @closed = false
    @heartbeater_started = false
    @sending = false
    @consumers = {} of UInt16 => Protocol::Frame+ ->
    @close_callbacks = [] of ->
  end

  def register_consumer(channel_id, &block: Protocol::Frame+ ->)
    @consumers[channel_id] = block
  end

  def unregister_consumer(channel_id)
    @consumers.delete(channel_id)
  end

  def send(channel, method)
    frame = Protocol::MethodFrame.new(channel, method)
    if method.has_content?
      frames = [frame] of Protocol::Frame
      unless method.responds_to?(:content)
        raise Protocol::FrameError.new("unable to obtain the method's content")
      end
      properties, payload = method.content
      frames << Protocol::HeaderFrame.new(channel, method.id.first, 0_u16, payload.length.to_u64)

      limit = @config.frame_max - Protocol::FRAME_HEADER_SIZE
      while payload && !payload.empty?
        body, payload = payload[0, limit], payload[limit, payload.length - limit]
        frames << Protocol::BodyFrame.new(channel, body.to_slice)
      end
      send_frames(frames)
    else
      send_frame(frame)
    end
  end

  private def send_frame(frame: Frame)
    Scheduler.yield while @sending
    @sending = true

    transmit_frame(frame)
  ensure
    @sending = false
  end

  private def send_frames(frames: Array(Frame))
    Scheduler.yield while @sending
    @sending = true

    frames.each {|frame| transmit_frame(frame)}
  ensure
    @sending = false
  end

  private def transmit_frame(frame)
    puts ">> #{frame}"
    frame.encode(@io)
    @sends.send(Time.now) if @heartbeater_started
  end

  def on_close(&block: ->)
    @close_callbacks << block
  end

  def close
    return if @closed
    @closed = true
    @sends.send(Time.now)
    @socket.close
    @close_callbacks.each &.call
  end

  def start_reader
    spawn { process_frames }
  end

  def start_heartbeater
    return if @heartbeater_started
    @heartbeater_started = true
    spawn { run_heartbeater }
  end

  private def process_frames
    loop do
      frame = Protocol::Frame.decode(@io)
      puts "<< #{frame}"

      case frame
      when Protocol::MethodFrame
        on_frame(frame)
      when Protocol::HeaderFrame
        on_frame(frame)
      when Protocol::BodyFrame
        on_frame(frame)
      when Protocol::HeartbeatFrame
        on_heartbeat
      else
        raise Protocol::FrameError.new "Invalid frame type received"
      end
    end
  rescue ex: Errno
    unless ex.errno == Errno::EBADF
      puts ex
      puts ex.backtrace.join("\n")
    end
    close
  rescue ex: IO::EOFError
    close
  rescue ex
    puts ex
    puts ex.backtrace.join("\n")
    close
  end

  private def on_frame(frame)
    consumer = @consumers[frame.channel]
    unless consumer
      raise Protocol::FrameError.new("Invalid channel received: #{frame.channel}")
    end
    consumer.call(frame)
  end

  private def on_heartbeat
  end

  private def run_heartbeater
    interval = @config.heartbeat
    loop do
      last_sent = Time.now
      send_time = @sends.receive(interval)
      break if @closed
      unless send_time
        # timeout received, fill the channel with heartbeats
        if Time.now - last_sent > interval
          heartbeat = Protocol::HeartbeatFrame.new
          send_frame(heartbeat)
        end
      else
        last_sent = send_time
      end
    end
  end

  def write_protocol_header
    @io.write(Slice.new(ProtocolHeader.buffer, ProtocolHeader.length))
  end
end
