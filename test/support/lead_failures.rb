# frozen_string_literal: true

# Exact failures reproduced against Lead 0e29dbe; see docs/lead-ci.md.
# Keep these tests enabled on production TIN and recheck when updating Lead.
module TinkickLeadFailures
  FAILURES = {
    "custom index analysis is ignored during Lead operator rechecks" => %w[
      AnalysisOptionsTest#test_declaring_one_analysis_option_does_not_override_the_other_index_policy
      AnalysisOptionsTest#test_case_sensitive_native_search_requires_a_matching_migrated_index
      AnalysisOptionsTest#test_omitted_options_adopt_custom_analysis_but_explicit_nil_requests_fold_defaults
      AnalysisOptionsTest#test_accent_sensitive_native_search_requires_a_matching_migrated_index
      ExclusionTest#test_exclusions_use_index_analysis_and_escape_partial_token_patterns
      CustomAnalysisSearchTest#test_each_selected_field_uses_its_own_index_analysis
      CustomAnalysisSearchTest#test_native_fuzzy_preserves_case_on_long_whole_words
      CustomAnalysisSearchTest#test_fuzzy_whitespace_tokens_escape_native_query_syntax_and_preserve_prefixes
      CustomAnalysisSearchTest#test_literal_words_use_the_index_case_accents_and_word_boundaries
      CustomAnalysisSearchTest#test_phrases_keep_indexed_whitespace_tokens_and_literal_punctuation
      CustomAnalysisSearchTest#test_long_native_fuzzy_tokens_preserve_prefixes_and_exact_exclusions
      CustomAnalysisSearchTest#test_partial_patterns_preserve_case_and_escape_tinql_and_regex_tokens
      CustomAnalysisSearchTest#test_reset_column_information_refreshes_analysis_after_index_rebuild
      CustomAnalysisSearchTest#test_warm_schema_reuses_analysis_without_another_index_catalog_read
      CustomAnalysisSearchTest#test_native_fuzzy_uses_custom_long_token_limits
      NativeHighlightBoundaryTest#test_changed_token_policy_highlighting_does_not_retokenize_prefixes
    ],
    "Lead scores only one selected field expression" => %w[
      FieldBoostTest#test_wildcard_boost_does_not_leak_into_an_independently_requested_concrete_field
      FieldBoostTest#test_field_weights_reverse_ranking_in_a_varied_corpus
      FieldBoostTest#test_fluent_fields_apply_boosts_without_mutating_the_original_relation
      FieldBoostTest#test_model_default_fields_apply_boosts_without_treating_them_as_schema_columns
      FieldBoostTest#test_zero_boost_keeps_matches_and_suppresses_only_the_selected_field_score
    ],
    "Lead does not score fuzzy term expansions" => %w[
      FieldBoostTest#test_native_two_edit_matching_keeps_its_field_boost
    ],
    "Lead cannot bind full_score in these weighted SQL query shapes" => %w[
      NumericBoostSearchTest#test_sql_field_scores_and_large_native_weights_compose_with_numeric_functions
      SqlFieldBoostTest#test_large_weights_preserve_hidden_highlight_inputs_and_column_cursors_without_implicit_count
      SqlFieldBoostTest#test_weighted_branches_preserve_filters_and_exclusions
      SqlFieldBoostTest#test_large_weights_keep_native_two_edit_matches
      SqlFieldBoostTest#test_large_native_weight_scales_scores_beyond_the_tinql_limit
      SqlFieldBoostTest#test_sql_weights_warn_once_for_cached_results_and_native_boosts_keep_the_fast_path
    ],
    "Lead elides common terms when scoring this small visible-row corpus" => %w[
      ProjectionTest#test_raw_source_projection_fetches_only_requested_columns_and_keeps_identity
      HitsTest#test_hits_expose_durable_identity_and_native_scores_without_counting
      RawValuesTest#test_raw_results_deserialize_postgresql_arrays_and_json_without_model_instantiation
    ],
  }.freeze

  def after_setup
    super
    return unless ENV["TINKICK_TEST_BACKEND"] == "lead"

    failure = FAILURES.find { |_reason, tests| tests.include?("#{self.class.name}##{name}") }
    skip "Verified Lead limitation: #{failure.first}; see docs/lead-ci.md" if failure
  end
end

ActiveSupport::TestCase.include(TinkickLeadFailures)
