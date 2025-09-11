# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# Configure your client
config :phoenix_socket_client,
  # The higher the value, the more verbose the client will be.
  # The supported values are:
  #
  #   * 0 - Disables all logging
  #   * 1 - Errors
  #   * 2 - Errors and warnings
  #   * 3 - Errors, warnings and info
  #   * 4 - Errors, warnings, info and debug (IO.inspects)
  #
  log_level: 0
  # topic_channel_map: %{},
  #
  # The `topic_channel_map` can be passed as an option to `PhoenixSocketClient.start_link/1`
  # to specify a custom channel module for a given topic.
  #
  # Example:
  #
  # PhoenixSocketClient.start_link(
  #   url: "ws://localhost:4000/socket",
  #   topic_channel_map: %{
  #     "my_topic" => MyApp.MyChannel
  #   }
  # )
