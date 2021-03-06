# encoding: utf-8

require 'lego_nxt/low_level'
require 'lego_nxt/low_level/types'
require 'lego_nxt/low_level/constants'
require 'lego_nxt/errors'

module LegoNXT::LowLevel
  # A mid-level API for talking to a LEGO NXT brick.
  class Brick
    # The connection object.
    #
    # @return [LegoNXT::UsbConnection, LegoNXT::SerialConnection]
    attr_reader :connection

    # @param [LegoNXT::UsbConnection, LegoNXT::SerialConnection] connection The connection object.
    def initialize connection
      @connection = connection
    end

    # Plays a tone.
    #
    # @param [Integer] frequency Range: 200-1400Hz
    # @param [Integer] duration in milliseconds (1/1000 of a second)
    # @return [nil]
    def play_tone frequency, duration
      raise ArgumentError.new("Frequency must be between 200-1400Hz; got #{frequency}") if frequency < 200 || frequency > 1400
      transmit(
        DirectOps::NO_RESPONSE,
        DirectOps::PLAYTONE,
        word(frequency),
        word(duration)
      )
    end

    # The battery level.
    #
    # @return [Integer] The voltage in millivolts.
    def battery_level
      transceive(
        DirectOps::REQUIRE_RESPONSE,
        DirectOps::GETBATTERYLEVEL,
      ).unpack('S<')[0]
    end


    def light_sensor(port, color=:none)
      sensor_type={
        full: SensorTypes::COLORFULL,
        red: SensorTypes::COLORRED,
        green: SensorTypes::COLORGREEN,
        blue: SensorTypes::COLORBLUE,
        none: SensorTypes::COLORNONE,
      }[color]

      raise ArgumentError, "Unknown color mode: #{color}" if sensor_type.nil?

      port_byte = normalize_sensor_port(port)
      transmit(
        DirectOps::NO_RESPONSE,
        DirectOps::SETINPUTMODE,
        port_byte,
        sensor_type,
        SensorModes::RAWMODE,
      )

      array = transceive(
        DirectOps::REQUIRE_RESPONSE,
        DirectOps::GETINPUTVALUES,
        port_byte,
      ).
      #bytes: 345678ACD
      unpack('CCCCCSSSS')

      (
        _, # Input port -- We know this, ignore it.
        _, # 0x01 if new data value should be seen as valid data
        is_calibrated, # 0x01 if calibration file found
        _, # Sensor Type -- We know this, ignore it.
        _, # Sensor Mode -- We know this, ignore it.
        _, # Raw A/D value
        _, # Normalized A/D value
        scaled_value, # Scaled A/D value
        calibrated_value, # Calibrated version of Scaled
      ) = array

      return is_calibrated ? calibrated_value : scaled_value
    ensure
      # Turn off the light.
      transmit(
        DirectOps::NO_RESPONSE,
        DirectOps::SETINPUTMODE,
        port_byte,
        SensorTypes::COLORNONE,
        SensorModes::RAWMODE,
      ) unless :none == color
    end

    # Resets the tracking for the motor position.
    #
    # @param [Symbol] port The port the motor is attached to. Should be `:a`, `:b`, or `:c`
    # @param [Boolean] set_relative Sets the position tracking to relative if true, otherwise absolute if false.
    # @return [nil]
    def reset_motor_position port, set_relative
      transmit(
        DirectOps::NO_RESPONSE,
        DirectOps::RESETMOTORPOSITION,
        normalize_motor_port(port),
        normalize_boolean(set_relative)
      )
    end

    # Runs the motor
    #
    # @param [Symbol] port The port the motor is attached to. Should be `:a`, `:b`, `:c`, `:all`
    # @param [Integer] power A number between -100 through 100 inclusive. Defaults to 100.
    # @return [nil]
    def run_motor port, power=100
      raise ArgumentError.new("Power must be -100 through 100") if power < -100 || power > 100
      transmit(
        DirectOps::NO_RESPONSE,
        DirectOps::SETOUTPUTSTATE,
        normalize_motor_port(port, true),
        sbyte(power), # power set point
        byte(1),      # mode
        byte(0),      # regulation mode
        sbyte(0),     # turn ratio
        byte(0x20),   # run state
        long(0),      # tacho limit
      )
    end

    # Stops the motor
    #
    # @param [Symbol] port The port the motor is attached to. Should be `:a`, `:b`, `:c`, `:all`
    # @return [nil]
    def stop_motor port
      run_motor port, 0
    end

    # A wrapper around the transmit function for the connection.
    #
    # @param [LegoNXT::Type] bits A list of bytes.
    # @return [nil]
    def transmit *bits
      bitstring = bits.map(&:byte_string).join("")
      connection.transmit bitstring
    end

    # A wrapper around the transceive function for the connection.
    #
    # The first three bytes of the return value are stripped off. Errors are
    # raised if they show a problem.
    #
    # @param [LegoNXT::Type] bits A list of bytes.
    # @return [String] The bytes returned; bytes 0 through 2 are stripped.
    def transceive *bits
      bitstring = bits.map(&:byte_string).join("")
      retval = connection.transceive bitstring
      # Check that it's a response bit.
      raise ::LegoNXT::BadResponseError unless retval[0] == "\x02"
      # Check that it's for this command.
      raise ::LegoNXT::BadResponseError unless retval[1] == bitstring[1]
      # Check that there is no error.
      # TODO: This should raise a specific error based on the status bit.
      raise ::LegoNXT::StatusError unless retval[2] == "\x00"
      return retval[3..-1]
    end

    # Converts a port symbol into the appropriate byte().
    #
    # @param [Symbol] port It should be `:a`, `:b`, `:c`, or `:all` (which correspond to the markings on the brick)
    # @param [Boolean] accept_all If true, then `:all` will be allowed, otherwise it's an error.
    # @return [UnsignedByte] The corresponding byte for the port.
    def normalize_motor_port port, accept_all=false
      @portmap ||= { a: byte(0),
                     b: byte(1),
                     c: byte(2),
                     all: byte(0xff),
      }
      raise ArgumentError.new("You cannot specify :all for this port") if port == :all and !accept_all
      raise ArgumentError.new("Motor ports must be #{@portmap.keys.inspect}: got #{port.inspect}") unless @portmap.include? port
      @portmap[port]
    end

    # Converts a port symbol into the appropriate byte().
    #
    # @param [Fixnum] port It should be 1, 2, 3, or 4 (which correspond to the markings on the brick )
    # @return [UnsignedByte] The corresponding byte for the port.
    def normalize_sensor_port port
      raw_port = Integer(port) - 1
      raise ArgumentError.new("Sensor ports must be 1 through 4: got #{port.inspect}") unless [0,1,2,3].include? raw_port
      byte(raw_port)
    end

    # Converts a boolean value into `byte(0)` or `byte(1)`
    #
    # @param [Object] bool The value to convert.
    # @return [UnsignedByte] Returns 0 or 1
    def normalize_boolean bool
      bool ? byte(1) : byte(0)
    end
  end
end
