#!/usr/bin/env ruby

require "stackprof"
StackProf.start(mode: :cpu, out: "stackprof.dump")
begin
  load File.join(__dir__, "../exe/type-profiler")
ensure
  StackProf.stop
  StackProf.results
end
