def foo
  case "foo"
  when "foo"
    1
  when "bar", "baz"
    :sym
  end
end

foo

__END__
Object#foo :: () -> (NilClass | Integer | Symbol)
