require 'json'
require 'pact/errors'
require 'pact/retry'
require 'pact/hal/entity'
require 'pact/hal/http_client'

# TODO move this to the pact broker client

module Pact
  module Provider
    module VerificationResults
      class PublicationError < Pact::Error; end

      class Publish

        PUBLISH_RELATION = 'pb:publish-verification-results'.freeze
        PROVIDER_RELATION = 'pb:provider'.freeze
        VERSION_TAG_RELATION = 'pb:version-tag'.freeze

        def self.call pact_source, verification_result
          new(pact_source, verification_result).call
        end

        def initialize pact_source, verification_result
          @pact_source = pact_source
          @verification_result = verification_result

          http_client_options = {}
          if pact_source.uri.basic_auth?
            http_client_options[:username] = pact_source.uri.username
            http_client_options[:password] = pact_source.uri.password
          end

          @http_client = Pact::Hal::HttpClient.new(http_client_options)
          @pact_entity = Pact::Hal::Entity.new(pact_source.pact_hash, http_client)
        end

        def call
          if can_publish_verification_results?
            tag_versions_if_configured
            publish_verification_results
          end
        end

        private
        attr_reader :pact_source, :verification_result, :pact_entity, :http_client

        def can_publish_verification_results?
          return false unless Pact.configuration.provider.publish_verification_results?

          if !pact_entity.can?(PUBLISH_RELATION)
            Pact.configuration.error_stream.puts "WARN: Cannot publish verification for #{consumer_name} as there is no link named pb:publish-verification-results in the pact JSON. If you are using a pact broker, please upgrade to version 2.0.0 or later."
            return false
          end

          if !verification_result.publishable?
            Pact.configuration.error_stream.puts "WARN: Cannot publish verification for #{consumer_name} as not all interactions have been verified. Re-run the verification without the filter parameters or environment variables to publish the verification."
            return false
          end
          true
        end

        def hacky_tag_url provider_entity
          hacky_tag_url = provider_entity._link('self').href + "/versions/{version}/tags/{tag}"
          Pact::Hal::Link.new('href' => hacky_tag_url)
        end

        def tag_versions_if_configured
          if Pact.configuration.provider.tags.any?
            if pact_entity.can?(PROVIDER_RELATION)
              tag_versions
            else
              Pact.configuration.error_stream.puts "WARN: Could not tag provider version as the pb:provider link cannot be found"
            end
          end
        end

        def tag_versions
          provider_entity = pact_entity.get(PROVIDER_RELATION)
          tag_link = provider_entity._link(VERSION_TAG_RELATION) || hacky_tag_url(provider_entity)
          provider_application_version = Pact.configuration.provider.application_version

          Pact.configuration.provider.tags.each do | tag |
            tag_entity = tag_link.expand(version: provider_application_version, tag: tag).put
            unless tag_entity.success?
              raise PublicationError.new("Error returned from tagging request #{tag_entity.response.code} #{tag_entity.response.body}")
            end
          end
        end

        def publish_verification_results
          verification_entity = nil
          begin
            # The verifications resource didn't have the content_types_provided set correctly, so publishing fails if we don't have */*
            verification_entity = pact_entity.post(PUBLISH_RELATION, verification_result, { "Accept" => "application/hal+json, */*" })
          rescue StandardError => e
            error_message = "Failed to publish verification results due to: #{e.class} #{e.message} #{e.backtrace.join("\n")}"
            raise PublicationError.new(error_message)
          end

          if verification_entity.success?
            new_resource_url = verification_entity._link('self').href
            Pact.configuration.output_stream.puts "INFO: Verification results published to #{new_resource_url}"
          else
            raise PublicationError.new("Error returned from verification results publication #{verification_entity.response.code} #{verification_entity.response.body}")
          end
        end

        def consumer_name
          pact_source.pact_hash['consumer']['name']
        end
      end
    end
  end
end
