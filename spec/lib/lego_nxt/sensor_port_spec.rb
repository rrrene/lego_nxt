require 'spec_helper'
require 'lego_nxt/sensor_port'

describe LegoNXT::SensorPort do
  subject(:sensor) { described_class.new }

  describe '#assign_brick_and_sensor_port' do
    let(:brick)       { instance_double('LegoNXT::Brick') }
    let(:port_number) { rand(4) + 1 }

    it 'assigns the brick' do
      subject.assign_brick_and_sensor_port(brick, port_number)
      subject.brick.should eq(brick)
    end

    it 'assigns the port' do
      subject.assign_brick_and_sensor_port(brick, port_number)
      subject.port.should eq(port_number)
    end
  end
end