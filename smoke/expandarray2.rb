def foo
  if rand < 0.5
    unknown
  else
    [:a, [:b, :c]]
  end
end

a, *bc = foo

p(a)

__END__
# Errors
smoke/expandarray2.rb:3: [error] undefined method: Object#unknown
# Revealed types
#  smoke/expandarray2.rb:11 #=> :a | any
# Classes
class Object
  foo : () -> ([:a, [:b, :c]] | any)
end
