def foo
  1.times do |_|
    return [:foo]
  end
end

def bar
  a = [:bar]
  1.times do |_|
    return a
  end
end

foo
bar

__END__
# Classes
class Object
  foo : () -> [:foo]
  bar : () -> [:bar]
end
