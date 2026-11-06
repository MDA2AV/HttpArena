require_relative 'app'

run Ractor.make_shareable(App.new)
