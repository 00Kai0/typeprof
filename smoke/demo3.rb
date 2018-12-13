# recursive method
def fib(x)
  if x <= 1
    x
  else
    fib(x - 1) + fib(x - 2)
  end
end

fib(40000)

__END__
Object#fib :: (Integer) -> Integer
