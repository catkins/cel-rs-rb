# frozen_string_literal: true

require "spec_helper"
require "time"

RSpec.describe CEL do
  describe ".compile" do
    it "compiles and executes simple expressions" do
      program = CEL.compile("1 + 1")
      expect(program.execute).to eq(2)
    end

    it "raises parse errors for invalid programs" do
      expect { CEL.compile("1 +") }.to raise_error(CEL::ParseError)
    end
  end

  describe CEL::Context do
    it "supports ruby variables for basic types" do
      context = CEL::Context.new
      context.add_variable("nil_value", nil)
      context.add_variable("flag", true)
      context.add_variable("num", 41)
      context.add_variable("float_num", 1.5)
      context.add_variable("name", "cel")
      context.add_variable("ary", [1, 2, 3])
      context.add_variable("obj", {"a" => 1, :b => 2})

      expect(CEL.compile("nil_value == null").execute(context)).to eq(true)
      expect(CEL.compile("flag && true").execute(context)).to eq(true)
      expect(CEL.compile("num + 1").execute(context)).to eq(42)
      expect(CEL.compile("float_num + 0.5").execute(context)).to eq(2.0)
      expect(CEL.compile("name.startsWith('c')").execute(context)).to eq(true)
      expect(CEL.compile("ary[2]").execute(context)).to eq(3)
      expect(CEL.compile("obj.a + obj.b").execute(context)).to eq(3)
    end

    it "supports ruby values for CEL bytes, timestamp, and duration types" do
      context = CEL::Context.build(
        bytes: "abc".b,
        at: Time.utc(2023, 5, 29),
        delay: CEL::Duration.new(90)
      )

      expect(CEL.compile("bytes == b'abc'").execute(context)).to eq(true)
      expect(CEL.compile("at == timestamp('2023-05-29T00:00:00Z')").execute(context)).to eq(true)
      expect(CEL.compile("delay == duration('90s')").execute(context)).to eq(true)
    end

    it "registers ruby functions and supports variadic calls" do
      context = CEL::Context.new
      context.define_function("sum") do |*values|
        values.flatten.sum
      end

      expect(CEL.compile("sum(1, 2, 3)").execute(context)).to eq(6)
    end

    it "passes method receiver as first block arg for method calls" do
      context = CEL::Context.new(true)
      context.define_function("startsWith") { |target, prefix| target.start_with?(prefix) }

      expect(CEL.compile("'hello'.startsWith('he')").execute(context)).to eq(true)
    end

    it "raises clear type error for unsupported variable types" do
      context = CEL::Context.new
      expect { context.add_variable("bad", Object.new) }.to raise_error(CEL::TypeError)
    end
  end

  describe CEL::Program do
    it "exposes references" do
      program = CEL.compile("size(foo) > 0")
      refs = program.references
      expect(refs["variables"]).to include("foo")
      expect(refs["functions"]).to include("size")
    end

    it "ports core CEL suite behavior examples" do
      tests = {
        "size([1,2,3]) == 3" => true,
        "[1,2,3].map(x, x * 2)" => [2, 4, 6],
        "[1,2,3].filter(x, x > 1)" => [2, 3],
        "[1,2,3].exists(x, x == 2)" => true,
        "[1,2,3].all(x, x > 0)" => true,
        "'a' in {'a': 1}" => true,
        "'abc'.contains('b')" => true,
        "optional.of(1).hasValue()" => true
      }

      tests.each do |expr, expected|
        expect(CEL.compile(expr).execute).to eq(expected)
      end
    end

    it "marshals current CEL scalar value variants back to ruby" do
      bytes = CEL.compile("b'abc'").execute
      expect(bytes).to eq("abc".b)
      expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)

      timestamp = CEL.compile("timestamp('2023-05-29T00:00:00Z')").execute
      expect(timestamp).to be_a(Time)
      expect(timestamp.getutc.iso8601).to eq("2023-05-29T00:00:00Z")

      duration = CEL.compile("duration('1m30s')").execute
      expect(duration).to be_a(CEL::Duration)
      expect(duration.total_seconds).to eq(90.0)
      expect(duration).to eq(CEL::Duration.new(90))
    end

    it "returns execution errors as CEL::ExecutionError" do
      program = CEL.compile("1 / 0")
      expect { program.execute }.to raise_error(CEL::ExecutionError)
    end

    it "releases GVL so other ruby threads can progress" do
      context = CEL::Context.new
      context.add_variable("items", Array.new(15_000, 1))
      program = CEL.compile("items.map(x, x + 1)")

      marker = Queue.new
      worker = Thread.new do
        100.times do
          marker << :tick
          sleep(0.001)
        end
      end

      runner = Thread.new { program.execute(context) }

      sleep(0.01)
      expect(marker.size).to be > 0

      runner.join
      worker.join
    end

    it "executes the same program concurrently with independent contexts" do
      program = CEL.compile("items.map(x, x + offset).filter(x, x > cutoff).size() + id")
      ready = Queue.new
      start = Queue.new

      threads = Array.new(8) do |id|
        Thread.new do
          ready << true
          start.pop

          offset = id % 3
          context = CEL::Context.build(
            id: id,
            items: Array.new(200, id),
            offset: offset,
            cutoff: id
          )

          25.times.map { program.execute(context) }
        end
      end
      8.times { ready.pop }
      8.times { start << true }
      results = threads.map(&:value)

      expected = Array.new(8) do |id|
        offset = id % 3
        value = (offset.zero? ? 0 : 200) + id
        Array.new(25, value)
      end

      expect(results).to eq(expected)
    end
  end
end
