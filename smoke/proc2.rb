# TODO: restart is needed?
def foo
  a = 1
  -> do
    a = "str"
  end.call
  a
end

foo

__END__
# Classes
class Object
  foo : () -> Integer
end
