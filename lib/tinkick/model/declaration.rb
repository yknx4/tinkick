# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  module Model
    module Declaration
      extend ActiveSupport::Concern

      def tinkick(searchable: Tinkick.model_options[:searchable], default_fields: Tinkick.model_options[:default_fields],
        match: Tinkick.model_options.fetch(:match, :word), stem: Tinkick.model_options.fetch(:stem, false),
        case_sensitive: Tinkick.model_options.fetch(:case_sensitive, Relation::NO_DEFAULT_VALUE),
        special_characters: Tinkick.model_options.fetch(:special_characters, Relation::NO_DEFAULT_VALUE),
        highlight: Tinkick.model_options[:highlight], filterable: Tinkick.model_options[:filterable],
        conversions: Tinkick.model_options[:conversions],
        conversions_v1: Tinkick.model_options.fetch(:conversions_v1, Relation::NO_DEFAULT_VALUE),
        conversions_v2: Tinkick.model_options[:conversions_v2], stem_conversions: Tinkick.model_options[:stem_conversions],
        word_start: Tinkick.model_options[:word_start],
        word_middle: Tinkick.model_options[:word_middle], word_end: Tinkick.model_options[:word_end],
        text_start: Tinkick.model_options[:text_start], text_middle: Tinkick.model_options[:text_middle],
        text_end: Tinkick.model_options[:text_end], **options)
        # @type self: singleton(ActiveRecord::Base)
        # @type var case_sensitive: bool? | Relation::DefaultValue
        # @type var special_characters: bool? | Relation::DefaultValue
        # @type var conversions_v1: conversion_fields | Relation::DefaultValue
        options = Tinkick.model_options.except(:searchable, :default_fields, :match, :stem, :case_sensitive, :special_characters, :highlight, :filterable,
          :conversions, :conversions_v1, :conversions_v2, :stem_conversions,
          :word_start, :word_middle, :word_end, :text_start, :text_middle, :text_end).merge(options)
        analysis = {} #: Hash[Symbol, bool?]
        analysis[:case_sensitive] = tinkick_analysis_flag(case_sensitive, :case_sensitive) unless case_sensitive.is_a?(Relation::DefaultValue)
        analysis[:special_characters] = tinkick_analysis_flag(special_characters, :special_characters) unless special_characters.is_a?(Relation::DefaultValue)
        tinkick_validate_stemming(stem, options)
        raise ArgumentError, "Only call tinkick once per model" if tinkick_options

        unless stem_conversions.nil? || stem_conversions == false
          raise NotImplementedError, "stem_conversions is not yet supported by TIN. Persist normalized query keys in JSONB conversion columns with a Rails migration and pass the same normalized conversions_term"
        end
        conversions = conversions_v1 unless conversions_v1.is_a?(Relation::DefaultValue)
        conversion_columns = tinkick_conversion_columns(conversions, conversions_v2)
        tinkick_validate_declarations(highlight, filterable, [word_start, word_middle, word_end, text_start, text_middle, text_end])
        declared = { searchable: searchable, default_fields: default_fields, match: match, highlight: highlight, filterable: filterable,
                     conversions: conversion_columns.fetch(0), conversions_v2: conversion_columns.fetch(1),
                     word_start: word_start, word_middle: word_middle, word_end: word_end,
                     text_start: text_start, text_middle: text_middle, text_end: text_end } #: model_options
        declared[:case_sensitive] = analysis[:case_sensitive] if analysis.key?(:case_sensitive)
        declared[:special_characters] = analysis[:special_characters] if analysis.key?(:special_characters)
        @tinkick_options = declared
        method_name = Tinkick.search_method_name
        if method_name && !respond_to?(method_name, true)
          singleton_class.alias_method(method_name, :tinkick_search)
        end
        Tinkick.models << self
      end

      def tinkick_options
        # @type self: singleton(ActiveRecord::Base)
        @tinkick_options || (superclass.respond_to?(:tinkick_options) ? superclass.public_send(:tinkick_options) : nil)
      end

      private

      def tinkick_validate_stemming(stem, options)
        raise ArgumentError, "stem must be true or false" unless stem == true || stem == false

        stemming = options.keys & [:language, :stemmer, :stem_exclusion, :stemmer_override]
        stemming.unshift(:stem) if stem
        unless stemming.empty?
          raise NotImplementedError, "Stemming (#{stemming.join(', ')}) is not yet supported by TIN. Use stem: false for native token matching, or add normalized stored columns with a Rails migration and normalize query text with the same rules"
        end
        raise ArgumentError, "unknown keywords: #{options.keys.join(', ')}" unless options.empty?
      end

      def tinkick_conversion_columns(conversions, conversions_v2)
        conversion_columns = [conversions, conversions_v2].map do |value|
          fields = value ? Array(value) : [] #: Array[String | Symbol]
          unless tinkick_field_names?(fields)
            raise ArgumentError, "conversions must name JSONB columns with a string, symbol, or array; false or nil disables them"
          end
          fields.map(&:to_s).uniq
        end
        unless (conversion_columns.fetch(0) & conversion_columns.fetch(1)).empty?
          raise ArgumentError, "A conversion column cannot be declared in both conversions and conversions_v2"
        end

        conversion_columns
      end

      def tinkick_validate_declarations(highlight, filterable, partial_fields)
        { highlight: highlight, filterable: filterable }.each do |option, declaration|
          unless !declaration || tinkick_field_names?(declaration)
            raise ArgumentError, "#{option} must be an array of field names, false, or nil"
          end
        end

        partial_fields.each do |fields|
          unless fields.nil? || tinkick_field_names?(fields)
            raise ArgumentError, "Partial match declarations must be arrays of field names"
          end
        end
      end

      def tinkick_field_names?(fields)
        fields.is_a?(Array) && fields.all? { |field| field.is_a?(String) || field.is_a?(Symbol) }
      end

      def tinkick_analysis_flag(value, option)
        return if value.nil?
        return true if value == true
        return false if value == false

        raise ArgumentError, "#{option} must be true, false, or nil"
      end
    end
  end
end
