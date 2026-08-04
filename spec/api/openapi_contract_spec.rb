# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "OpenAPI route contract" do
  subject(:document) { RSpec.configuration.openapi_specs.fetch("v1/swagger.json") }

  let(:http_methods) { %i[get post put patch delete] }
  let(:documented_operations) do
    document.fetch(:paths).flat_map do |path, path_item|
      path_item.filter_map do |verb, operation|
        next unless http_methods.include?(verb)

        [verb.to_s.upcase, path, operation]
      end
    end
  end

  it "covers the reviewed application route inventory" do
    expected = OpenapiRouteCatalog.operations.map { |operation| [operation[:verb], operation[:path]] }.sort
    actual = documented_operations.map { |verb, path, _operation| [verb, path] }.sort

    expect(actual).to eq(expected)
    expect(OpenapiRouteCatalog.api_operation_digest)
      .to eq(OpenapiRouteCatalog::AUDITED_API_OPERATION_DIGEST), <<~MESSAGE
        The application API route surface changed. Recheck the React callers,
        callbacks, scheduler/documentation references, and Orphaned classification,
        then update AUDITED_API_OPERATION_DIGEST.
      MESSAGE
  end

  it "defines the lifecycle tags" do
    tag_names = document.fetch(:tags).map { |tag| tag.fetch(:name) }

    expect(tag_names).to include(*OpenapiRouteCatalog::LIFECYCLE_TAGS)
  end

  it "gives every operation complete and unique metadata" do
    operation_ids = documented_operations.map { |_verb, _path, operation| operation.fetch(:operationId) }

    expect(operation_ids).to all(be_present)
    expect(operation_ids.uniq.length).to eq(operation_ids.length)

    documented_operations.each do |verb, path, operation|
      aggregate_failures("#{verb} #{path}") do
        expect(operation.fetch(:summary)).to be_present
        expect(operation.fetch(:description)).to be_present
        expect(operation.fetch(:responses)).to be_present

        tags = operation.fetch(:tags)
        lifecycle_tags = tags & OpenapiRouteCatalog::LIFECYCLE_TAGS
        expect(tags.length).to be >= 2
        expect(lifecycle_tags.length).to eq(1)
        expect(tags.first).not_to be_in(OpenapiRouteCatalog::LIFECYCLE_TAGS)
      end
    end
  end

  it "uses the application root and provider content types for webhooks" do
    expected_content_types = {
      "/ipnlistener" => "application/x-www-form-urlencoded",
      "/mailtrap_listener" => "application/json",
      "/billing/braintree_listener" => "application/x-www-form-urlencoded",
      "/slack/commands/checkout" => "application/x-www-form-urlencoded",
      "/slack/commands/reserve" => "application/x-www-form-urlencoded",
      "/slack/commands/volunteer" => "application/x-www-form-urlencoded",
      "/slack/interactions" => "application/x-www-form-urlencoded"
    }

    expected_content_types.each do |path, content_type|
      operation = document.dig(:paths, path, :post)

      aggregate_failures(path) do
        expect(operation.fetch(:tags)).to include("Webhook")
        expect(operation.fetch(:servers)).to eq([{ url: "/", description: "Application root" }])
        expect(operation.dig(:requestBody, :content).keys).to eq([content_type])
      end
    end
  end

  it "keeps intentionally excluded framework and page routes out of the document" do
    documented_keys = documented_operations.map do |verb, path, _operation|
      OpenapiRouteCatalog.canonical_key(verb, path)
    end

    expect(documented_keys).not_to include(*OpenapiRouteCatalog::EXCLUDED_API_OPERATIONS)
    expect(document.fetch(:paths).keys).not_to include(
      "/", "/favicon.ico", "/*path", "/volunteer/bounties", "/volunteer/leaderboard"
    )
  end
end
