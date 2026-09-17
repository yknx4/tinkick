# frozen_string_literal: true

require_relative "errors"

module Tinkick
  # Sparse deterministic Unicode transitions. Missing transitions reject input.
  class RegexAutomaton
    MAX_CODEPOINT = 0x10ffff

    # This bounds adapter compilation work, not Elasticsearch's determinizer.
    class Work
      def initialize(limit = 1_000_000)
        @remaining = limit
      end

      def consume(amount = 1)
        @remaining -= amount
        if @remaining.negative?
          raise InvalidQueryError, "Regular expression compilation work budget exceeded; simplify the expression"
        end
      end
    end

    attr_reader :edges, :finals, :work

    class << self
      def empty(work: Work.new)
        new([[]], [], work: work)
      end

      def epsilon(work: Work.new)
        new([[]], [0], work: work)
      end

      def characters(lower, upper = lower, work: Work.new)
        unless lower >= 0 && upper <= MAX_CODEPOINT && lower <= upper
          raise InvalidQueryError, "Invalid regular expression character interval"
        end
        new([[[lower, upper, 1]], []], [1], work: work)
      end

      def any(work: Work.new)
        characters(0, MAX_CODEPOINT, work: work)
      end

      def all(work: Work.new)
        new([[[0, MAX_CODEPOINT, 0]]], [0], work: work)
      end

      def literal(text, work: Work.new)
        work.consume(text.length)
        # @type var edges: graph
        edges = text.codepoints.each_with_index.map { |point, index| [[point, point, index + 1]] }
        edges << []
        new(edges, [edges.length - 1], work: work)
      end

      def determinize(edges, epsilon, finals, start, work:)
        work.consume(edges.length)
        edges.each { |row| work.consume(row.length) }
        closure = lambda do |states|
          found = states.to_h { |state| [state, true] }
          pending = states.dup
          until pending.empty?
            work.consume
            epsilon.fetch(pending.pop, []).each do |state|
              next if found.key?(state)

              found[state] = true
              pending << state
            end
          end
          found.keys.sort
        end
        accepting = finals.to_h { |state| [state, true] }
        queue = [closure.call(start)]
        indices = { queue.first => 0 }
        output = [] #: graph
        final_states = [] #: Array[Integer]
        index = 0
        while index < queue.length
          states = queue.fetch(index)
          final_states << index if states.any? { |state| accepting.key?(state) }
          transitions = states.flat_map { |state| edges.fetch(state) }
          bounds = transitions.flat_map { |lo, hi, _| [lo, hi + 1] }.uniq.sort
          outgoing = [] #: Array[edge]
          bounds.each_cons(2) do |pair|
            lo, following = pair.fetch(0), pair.fetch(1)
            work.consume(transitions.length)
            targets = transitions.filter_map { |lower, upper, target| target if lower <= lo && lo <= upper }
            next if targets.empty?

            destination = closure.call(targets)
            unless indices.key?(destination)
              indices[destination] = queue.length
              queue << destination
            end
            append(outgoing, lo, following - 1, indices.fetch(destination))
          end
          output << outgoing
          index += 1
        end
        new(output, final_states, work: work)
      end

      # Digit-state construction never enumerates individual integers in a range.
      def interval(lower, upper, width = 0, work: Work.new)
        lower, upper = upper, lower if lower > upper
        if lower.negative? || width.negative? || (width.positive? && upper.to_s.length > width)
          raise InvalidQueryError, "Invalid regular expression decimal interval"
        end
        return fixed_interval(lower, upper, width, work: work).minimize if width.positive?

        range = empty(work: work)
        (lower.to_s.length..upper.to_s.length).each do |digits|
          minimum = [lower, digits == 1 ? 0 : Integer(10**(digits - 1))].max || lower
          maximum = [upper, Integer(10**digits) - 1].min || upper
          range = range.union(fixed_interval(minimum, maximum, digits, work: work))
        end
        characters(48, work: work).repeat.concatenate(range)
      end

      def append(edges, lower, upper, target)
        previous = edges.last
        if previous && previous.fetch(2) == target && previous.fetch(1) + 1 == lower
          previous[1] = upper
        else
          edges << [lower, upper, target]
        end
      end

      def fixed_interval(lower, upper, digits, work:)
        work.consume(digits)
        low = lower.to_s.rjust(digits, "0").chars.map(&:to_i)
        high = upper.to_s.rjust(digits, "0").chars.map(&:to_i)
        queue = [[0, true, true]] #: Array[[Integer, bool, bool]]
        indices = { queue.fetch(0) => 0 } #: Hash[[Integer, bool, bool], Integer]
        edges = [] #: graph
        finals = [] #: Array[Integer]
        index = 0
        while index < queue.length
          position, low_tight, high_tight = queue.fetch(index)
          outgoing = [] #: Array[edge]
          if position == digits
            finals << index
          else
            minimum = low_tight ? low.fetch(position) : 0
            maximum = high_tight ? high.fetch(position) : 9
            (minimum..maximum).each do |digit|
              work.consume
              next_state = [position + 1, low_tight && digit == minimum, high_tight && digit == maximum] #: [Integer, bool, bool]
              unless indices.key?(next_state)
                indices[next_state] = queue.length
                queue << next_state
              end
              append(outgoing, 48 + digit, 48 + digit, indices.fetch(next_state))
            end
          end
          edges << outgoing
          index += 1
        end
        new(edges, finals, work: work)
      end
    end

    def initialize(edges, finals, work: Work.new)
      work.consume(edges.length)
      edges.each { |row| work.consume(row.length) }
      @edges = edges.map { |row| row.map { |edge| edge.dup.freeze }.freeze }.freeze
      @finals = finals.uniq.sort.freeze
      @accepting = @finals.to_h { |state| [state, true] }
      @work = work
    end

    def run(text)
      state = 0
      text.each_codepoint do |point|
        state = target(state, point)
        return false if state == -1
      end
      accepting?(state)
    end

    def accepting?(state)
      @accepting.key?(state)
    end

    def target(state, point)
      return -1 if state == -1

      edge = @edges.fetch(state).find { |lower, upper, _| lower <= point && point <= upper }
      edge ? edge.fetch(2) : -1
    end

    def union(other)
      product(other, :union)
    end

    def intersection(other)
      product(other, :intersection)
    end

    def complement
      edges = complete_edges
      finals = edges.each_index.reject { |state| accepting?(state) }
      self.class.new(edges, finals, work: @work).minimize
    end

    def concatenate(other)
      return self.class.empty(work: @work) if @finals.empty? || other.finals.empty?
      return other if epsilon?
      return self if other.epsilon?

      shift = @edges.length
      edges = @edges.dup
      edges.concat(other.edges.map { |row| row.map { |lo, hi, target| [lo, hi, target + shift] } })
      epsilon = @finals.to_h { |state| [state, [shift]] }
      self.class.determinize(edges, epsilon, other.finals.map { |state| state + shift }, [0], work: @work).minimize
    end

    def repeat
      # Pinned Lucene 9.12.2 retains the empty language for an unbounded star.
      return self if @finals.empty? || epsilon? || universal?

      edges = [[]] #: graph
      edges.concat(@edges.map { |row| row.map { |lo, hi, target| [lo, hi, target + 1] } })
      epsilon = { 0 => [1] }
      @finals.each { |state| epsilon[state + 1] = [1] }
      finals = [0] + @finals.map { |state| state + 1 }
      self.class.determinize(edges, epsilon, finals, [0], work: @work).minimize
    end

    def bounds(minimum, maximum)
      if minimum.negative? || (maximum && maximum < minimum)
        raise InvalidQueryError, "Invalid regular expression repetition bounds"
      end
      return self.class.epsilon(work: @work) if maximum == 0
      return self if epsilon? || universal?
      if @finals.empty?
        return minimum.zero? && maximum ? self.class.epsilon(work: @work) : self
      end

      count = maximum || minimum + 1
      @work.consume(count * @edges.length)
      # Build one epsilon NFA, instead of repeatedly copying growing prefixes.
      edges = [[]] #: graph
      epsilon = {} #: Hash[Integer, Array[Integer]]
      previous = [0]
      finals = minimum.zero? ? [0] : [] #: Array[Integer]
      count.times do |index|
        shift = edges.length
        edges.concat(@edges.map { |row| row.map { |lo, hi, target| [lo, hi, target + shift] } })
        previous.each { |state| epsilon[state] = [shift] }
        previous = @finals.map { |state| state + shift }
        finals.concat(previous) if index + 1 >= minimum
        previous.each { |state| epsilon[state] = [shift] } if maximum.nil? && index == count - 1
      end
      self.class.determinize(edges, epsilon, finals, [0], work: @work).minimize
    end

    def epsilon?
      @edges.length == 1 && @edges.first == [] && accepting?(0)
    end

    def universal?
      @edges == [[[0, MAX_CODEPOINT, 0]]] && accepting?(0)
    end

    # Hopcroft partition refinement over interval preimages avoids a global
    # Unicode alphabet expansion and repeated full-graph signature scans.
    def minimize
      return self.class.empty(work: @work) if @finals.empty?

      complete = complete_edges
      incoming = Array.new(complete.length) { [] } #: graph
      complete.each_with_index do |row, source|
        row.each { |lo, hi, target| incoming.fetch(target) << [lo, hi, source] }
      end
      partitions = [@finals.to_h { |state| [state, true] }, {}] #: Array[states]
      membership = Array.new(complete.length, 1)
      complete.each_index do |state|
        if accepting?(state)
          membership[state] = 0
        else
          partitions.fetch(1)[state] = true
        end
      end
      queue = [0, 1]
      position = 0
      while position < queue.length
        block = queue.fetch(position)
        position += 1
        events = {} #: Hash[Integer, Array[[Integer, Integer]]]
        partitions.fetch(block).each_key do |state|
          incoming.fetch(state).each do |lo, hi, source|
            (events[lo] ||= []) << [source, 1]
            (events[hi + 1] ||= []) << [source, -1]
          end
        end
        active = {} #: Hash[Integer, Integer]
        events.keys.sort.each do |point|
          events.fetch(point).each do |source, difference|
            total = active.fetch(source, 0) + difference
            if total.zero?
              active.delete(source)
            else
              active[source] = total
            end
          end
          @work.consume(active.length + events.fetch(point).length)
          split_partitions(active.keys, partitions, membership, queue)
        end
      end
      reduced_edges(complete, partitions, membership)
    end

    private

    def product(other, operation)
      queue = [[0, 0]] #: Array[[Integer, Integer]]
      indices = { queue.fetch(0) => 0 } #: Hash[[Integer, Integer], Integer]
      edges = [] #: graph
      finals = [] #: Array[Integer]
      position = 0
      while position < queue.length
        left, right = queue.fetch(position)
        accepted = if operation == :union
          accepting?(left) || other.accepting?(right)
        else
          accepting?(left) && other.accepting?(right)
        end
        finals << position if accepted
        bounds = [0, MAX_CODEPOINT + 1]
        rows = [left == -1 ? [] : @edges.fetch(left), right == -1 ? [] : other.edges.fetch(right)] #: graph
        rows.each do |row|
          row.each { |lo, hi, _| bounds.concat([lo, hi + 1]) }
        end
        outgoing = [] #: Array[edge]
        bounds.uniq.sort.each_cons(2) do |pair|
          lo, following = pair.fetch(0), pair.fetch(1)
          @work.consume(1 + rows.fetch(0).length + rows.fetch(1).length)
          pair = [target(left, lo), other.target(right, lo)] #: [Integer, Integer]
          unless indices.key?(pair)
            indices[pair] = queue.length
            queue << pair
          end
          self.class.append(outgoing, lo, following - 1, indices.fetch(pair))
        end
        edges << outgoing
        position += 1
      end
      self.class.new(edges, finals, work: @work).minimize
    end

    def complete_edges
      sink = @edges.length
      @work.consume(sink)
      complete = @edges.map do |row|
        outgoing = [] #: Array[edge]
        position = 0
        row.each do |lo, hi, target|
          self.class.append(outgoing, position, lo - 1, sink) if position < lo
          self.class.append(outgoing, lo, hi, target)
          position = hi + 1
        end
        self.class.append(outgoing, position, MAX_CODEPOINT, sink) if position <= MAX_CODEPOINT
        outgoing
      end
      complete << [[0, MAX_CODEPOINT, sink]]
    end

    def split_partitions(sources, partitions, membership, queue)
      sources.group_by { |state| membership.fetch(state) }.each do |block, inside|
        original = partitions.fetch(block)
        next if inside.length == original.length

        # Only states in the smaller side change their membership identifier.
        selected = inside.to_h { |state| [state, true] }
        selected = original.reject { |state, _| selected.key?(state) } if selected.length > original.length / 2
        destination = partitions.length
        selected.each_key do |state|
          original.delete(state)
          membership[state] = destination
        end
        partitions << selected
        queue << destination
      end
    end

    def reduced_edges(complete, partitions, membership)
      dead = membership.fetch(@edges.length)
      start = membership.fetch(0)
      return self.class.empty(work: @work) if start == dead

      queue = [start]
      indices = { start => 0 }
      edges = [] #: graph
      finals = [] #: Array[Integer]
      position = 0
      while position < queue.length
        state = partitions.fetch(queue.fetch(position)).keys.fetch(0)
        finals << position if accepting?(state)
        outgoing = [] #: Array[edge]
        complete.fetch(state).each do |lo, hi, target|
          destination = membership.fetch(target)
          next if destination == dead

          unless indices.key?(destination)
            indices[destination] = queue.length
            queue << destination
          end
          self.class.append(outgoing, lo, hi, indices.fetch(destination))
        end
        edges << outgoing
        position += 1
      end
      self.class.new(edges, finals, work: @work)
    end
  end
end
