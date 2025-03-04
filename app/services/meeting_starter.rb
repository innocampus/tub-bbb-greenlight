# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/.
#
# Copyright (c) 2022 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# Greenlight is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with Greenlight; if not, see <http://www.gnu.org/licenses/>.

# frozen_string_literal: true

require 'uri'

class MeetingStarter
  include Rails.application.routes.url_helpers

  def initialize(room:, base_url:, current_user:, provider:)
    @room = room
    @current_user = current_user
    @base_url = base_url
    @provider = provider
  end

  def call
    # TODO: amir - Check the legitimately of the action.
    options = RoomSettingsGetter.new(room_id: @room.id, provider: @room.user.provider, current_user: @current_user, only_bbb_options: true).call
    viewer_code = RoomSettingsGetter.new(
      room_id: @room.id,
      provider: @room.user.provider,
      current_user: @current_user,
      show_codes: true,
      settings: 'glViewerAccessCode'
    ).call

    handle_server_tag(meeting_options: options)

    options.merge!(computed_options(access_code: viewer_code['glViewerAccessCode']))

    retries = 0
    begin
      meeting = BigBlueButtonApi.new(provider: @provider).start_meeting(room: @room, options:, presentation_url:)

      @room.update!(online: true, last_session: DateTime.strptime(meeting[:createTime].to_s, '%Q'))

      ActionCable.server.broadcast "#{@room.friendly_id}_rooms_channel", 'started'
    rescue BigBlueButton::BigBlueButtonException => e
      retries += 1
      retry if retries < 3 && e.key != 'idNotUnique'
      raise e
    end
  end

  private

  def computed_options(access_code:)
    room_url = "#{root_url(host: @base_url)}rooms/#{@room.friendly_id}/join"
    moderator_message = "#{I18n.t('meeting.moderator_message', locale: @current_user&.language&.to_sym)}<br>#{room_url}"
    moderator_message += "<br>#{I18n.t('meeting.access_code', code: access_code, locale: @current_user&.language&.to_sym)}" if access_code.present?
    {
      moderatorOnlyMessage: moderator_message,
      loginURL: room_url,
      logoutURL: room_url,
      meta_endCallbackUrl: meeting_ended_url(host: @base_url),
      'meta_bbb-recording-ready-url': recording_ready_url(host: @base_url),
      'meta_bbb-origin': 'greenlight',
      'meta_bbb-origin-server-name': URI(@base_url).host,
      'meta_bbb-origin-version': ENV.fetch('VERSION_TAG', 'v3'),
      'meta_bbb-context-name': @room.name,
      'meta_bbb-context-id': @room.friendly_id
    }
  end

  def handle_server_tag(meeting_options:)
    if meeting_options['serverTag'].present?
      tag_names = Rails.configuration.server_tag_names
      tag_roles = Rails.configuration.server_tag_roles
      tag = meeting_options.delete('serverTag')
      tag_required = meeting_options.delete('serverTagRequired')
      # handle override modes
      if Rails.configuration.server_tag_fallback_mode == 'required'
        tag_required = 'true'
      elsif Rails.configuration.server_tag_fallback_mode == 'desired'
        tag_required = 'false'
      end

      if tag_names.key?(tag) && !(tag_roles.key?(tag) && tag_roles[tag].exclude?(@room.user.role_id))
        tag_param = tag_required == 'true' ? "#{tag}!" : tag
        meeting_options.store('meta_server-tag', tag_param)
      end
    else
      meeting_options.delete('serverTag')
      meeting_options.delete('serverTagRequired')
    end
  end

  def presentation_url
    return unless @room.presentation.attached?

    rails_blob_url(@room.presentation, host: @base_url).gsub('&', '%26')
  end
end
