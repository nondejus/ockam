defmodule Ockam.Transport.TCP.Connection do
  use GenStateMachine, callback_mode: :state_functions

  require Logger

  alias Ockam.Transport
  alias Ockam.Transport.Socket
  alias Ockam.Channel
  alias Ockam.Channel.Handshake
  alias Ockam.Vault
  alias Ockam.Vault.KeyPair
  alias Ockam.Vault.SecretAttributes
  alias Ockam.Router
  alias Ockam.Router.Protocol.Message
  alias Ockam.Router.Protocol.Message.Envelope
  alias Ockam.Router.Protocol.Message.Payload
  alias Ockam.Router.Protocol.Encoding

  @protocol "Noise_XX_25519_AESGCM_SHA256"

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      shutdown: 1_000,
      type: :worker
    }
  end

  defmodule State do
    defstruct [
      :socket,
      :data,
      :mode,
      :select_info,
      :handshake,
      :channel,
      :next,
      :vault,
      :connected
    ]
  end

  def start_link(_opts, socket) do
    GenStateMachine.start_link(__MODULE__, [socket])
  end

  def init([socket]) do
    {:ok, vault} = Vault.new()
    data = %State{socket: socket, data: "", select_info: nil, vault: vault}
    {:ok, :initializing, data}
  end

  def initializing({:call, from}, {:socket_controller, _conn}, %State{vault: vault} = data) do
    GenStateMachine.reply(from, :ok)
    attrs = SecretAttributes.x25519(:ephemeral)
    e = KeyPair.new(vault, attrs)
    s = KeyPair.new(vault, attrs)

    {:ok, handshake} = Channel.handshake(vault, :responder, %{protocol: @protocol, e: e, s: s})

    next = Handshake.next_message(handshake)
    new_data = %State{data | handshake: handshake, next: next}
    {:next_state, :handshake, new_data, [{:next_event, :internal, next}]}
  catch
    type, reason ->
      log_error("Failed to initialize connection: #{inspect({type, reason})}")
      stop(data, {type, reason})
  end

  def handshake(:internal, :in, %State{socket: socket, handshake: hs} = data) do
    log_debug("Awaiting handshake message..")

    with {:ok, encoded, socket} <- Transport.recv_nonblocking(socket),
         {:decode, {:ok, %Envelope{body: %Payload{data: payload}}, _}} <-
           {:decode, Encoding.decode(encoded)},
         {:ok, hs, _payload} <- Handshake.read_message(hs, payload) do
      case Handshake.next_message(hs) do
        :done ->
          log_debug("Handshake complete")
          {:ok, chan} = Handshake.finalize(hs)

          {:next_state, :connected,
           %State{data | socket: socket, handshake: nil, channel: chan, next: :done},
           [{:next_event, :internal, :ack}]}

        next ->
          log_debug("Handshake transitioning to #{inspect(next)}")

          {:keep_state, %State{data | socket: socket, handshake: hs, next: next},
           [{:next_event, :internal, next}]}
      end
    else
      {:wait, {:recv, info}, socket} ->
        log_debug("No data to receive, entering wait state")
        {:keep_state, %State{data | socket: socket, select_info: info, next: :in}}

      {:decode, {:ok, message, _}} ->
        log_warn(
          "Unexpected message received during handshake, expected Payload, got: #{
            inspect(message)
          }"
        )

        throw(:shutdown)

      {:decode, {:error, reason}} ->
        throw(reason)

      {:error, reason} ->
        throw(reason)
    end
  catch
    :throw, reason ->
      log_error("Error occurred while receiving handshake message: #{inspect(reason)}")
      stop(data, reason)
  end

  def handshake(:internal, :out, %State{socket: socket, handshake: hs} = data) do
    log_debug("Generating handshake message")

    with {:ok, hs, msg} <- Handshake.write_message(hs, ""),
         {:ok, encoded} <- Encoding.encode(%Payload{data: msg}),
         {:ok, socket} <- Transport.send(socket, encoded) do
      case Handshake.next_message(hs) do
        :done ->
          log_debug("Handshake complete")
          {:ok, chan} = Handshake.finalize(hs)

          {:next_state, :connected,
           %State{data | socket: socket, handshake: nil, channel: chan, next: :done},
           [{:next_event, :internal, :ack}]}

        next ->
          log_debug("Handshake transitioning to #{inspect(next)}")

          {:keep_state, %State{data | socket: socket, handshake: hs, next: next},
           [{:next_event, :internal, next}]}
      end
    else
      {:error, reason} ->
        throw(reason)
    end
  catch
    :throw, reason ->
      log_error("Error occurred while sending handshake message: #{inspect(reason)}")
      stop(data, reason)
  end

  def handshake(
        :info,
        {:"$socket", _socket, :select, info} = msg,
        %State{select_info: info, next: next} = data
      ) do
    log_debug("Waking up for receive, entering #{inspect(next)}")
    {:ok, :recv, new_socket} = Socket.handle_message(data.socket, msg)
    handshake(:internal, next, %State{data | socket: new_socket, select_info: nil})
  end

  def handshake(
        :info,
        {:"$socket", _socket, :abort, {info, _reason}} = msg,
        %State{select_info: info} = data
      ) do
    log_debug("Cancelling receive due to abort")
    {:error, {:abort, reason}, new_socket} = Socket.handle_message(data.socket, msg)
    stop(%State{data | socket: new_socket, select_info: nil}, reason)
  end

  def connected(:internal, :ack, %State{} = data) do
    log_debug("Connection established, sending ping..")
    # Send ACK then start receiving
    with {:ok, new_data} <- send_reply(%Message.Ping{}, data) do
      {:keep_state, new_data, [{:next_event, :internal, :receive}]}
    end
  end

  def connected(:internal, :receive, %State{socket: socket, channel: chan} = data) do
    log_debug("Entering receive state..")

    with {:ok, encrypted, socket} <- Transport.recv_nonblocking(socket),
         {_, {:ok, new_chan, decrypted}} <- {:decrypt, Channel.decrypt(chan, encrypted)},
         {_, {:ok, decoded, _}} <- {:decode, Encoding.decode(decrypted)} do
      handle_message(decoded, %State{data | socket: socket, channel: new_chan})
    else
      {:wait, {:recv, info}, socket} ->
        {:keep_state, %State{data | socket: socket, select_info: info}}

      {:decrypt, {:error, reason}} ->
        log_warn("Decrypt failed: #{inspect(reason)}")
        throw(:failed_decrypt)

      {:decode, {:error, reason}} ->
        log_warn("Decoding failed #{inspect(reason)}")
        throw(:failed_decode)

      {:error, :closed} ->
        log_debug("Socket closed")
        stop(data, :shutdown)

      {:error, reason} ->
        throw(reason)

      other ->
        log_error("Invalid return value in `connected`: #{inspect(other)}")
        throw(:fatal_error)
    end
  catch
    :throw, reason ->
      log_error("Error occurred while receiving: #{inspect(reason)}")
      stop(data, reason)
  end

  def connected(
        :info,
        {:"$socket", _socket, :select, info} = msg,
        %State{select_info: info} = data
      ) do
    {:ok, :recv, new_socket} = Socket.handle_message(data.socket, msg)
    connected(:internal, :receive, %State{data | socket: new_socket, select_info: nil})
  end

  def connected(
        :info,
        {:"$socket", _socket, :abort, {info, _reason}} = msg,
        %State{select_info: info} = data
      ) do
    {:error, {:abort, reason}, new_socket} = Socket.handle_message(data.socket, msg)
    stop(%State{data | socket: new_socket, select_info: nil}, reason)
  end

  def connect(type, msg, state) do
    log_warn("Unexpected message received in :connect state: #{inspect({type, msg})}")
    {:keep_state, state, [{:next_event, :internal, :receive}]}
  end

  defp handle_message(%Envelope{body: %Message.Pong{}}, %State{} = data) do
    log_debug("Ping was received and acknowledged via pong successfully!")
    {:keep_state, data, [{:next_event, :internal, :receive}]}
  end

  defp handle_message(
         %Envelope{headers: headers, body: %Message.Connect{}},
         %State{connected: nil} = data
       ) do
    log_debug("Received request to connect service")

    with {_, {:ok, dest}} <- {:send_to, Map.fetch(headers, :send_to)},
         {_, {:ok, conn}} <- {:connect, Router.connect(dest)},
         {:ok, new_data} = send_reply(%Message.Ack{}, %State{data | connected: conn}) do
      {:keep_state, new_data, [{:next_event, :internal, :receive}]}
    else
      {:connect, {:error, reason}} ->
        {:ok, new_data} = send_reply(Message.Error.new(1, reason), data)

        {:keep_state, new_data, [{:next_event, :internal, :receive}]}

      {:send_to, :error} ->
        log_warn("Message.Connect is missing send_to header!")
        stop(data, :invalid_message)

      {:error, reason} ->
        log_error("Error occurred while fulfilling connection request: #{inspect(reason)}")
        stop(data, reason)

      {:stop, _, _} = stop ->
        stop

      other ->
        log_error("Invalid return value in handle_message: #{inspect(other)}")
        stop(data, :fatal_error)
    end
  catch
    type, reason ->
      log_error("Fatal error occurred during message handling: #{inspect({type, reason})}")
      :erlang.raise(type, reason, __STACKTRACE__)
  end

  defp handle_message(%Envelope{body: %Message.Connect{}}, %State{} = data) do
    log_warn("Received request to connect service while connected to another service")

    {:ok, new_data} =
      send_reply(Message.Error.new(1, "cannot connect to more than one service at a time"), data)

    {:keep_state, new_data, [{:next_event, :internal, :receive}]}
  end

  defp handle_message(
         %Envelope{body: %Message.Send{data: message}},
         %State{connected: conn} = data
       ) do
    log_debug("Received send message")

    with {_, :ok} <- {:send, Router.send(conn, message)},
         {:ok, new_data} <- send_reply(%Message.Ack{}, data) do
      {:keep_state, new_data, [{:next_event, :internal, :receive}]}
    else
      {:send, {:error, reason}} ->
        {:ok, new_data} = send_reply(Message.Error.new(1, reason), data)
        {:keep_state, new_data, [{:next_event, :internal, :receive}]}

      {:error, reason} ->
        log_error("Error occurred while sending reply: #{inspect(reason)}")
        stop(data, reason)

      {:stop, _, _} = stop ->
        stop
    end
  end

  defp handle_message(
         %Envelope{body: %Message.Request{data: message}},
         %State{connected: conn} = data
       ) do
    log_debug("Received request message")

    with {_, {:ok, reply}} = {:request, Router.request(conn, message)},
         {:ok, new_data} <- send_reply(%Message.Payload{data: reply}, data) do
      {:keep_state, new_data, [{:next_event, :internal, :receive}]}
    else
      {:request, {:error, reason}} ->
        {:ok, new_data} = send_reply(Message.Error.new(1, reason), data)
        {:keep_state, new_data, [{:next_event, :internal, :receive}]}

      {:error, reason} ->
        log_error("Error occurred while sending reply: #{inspect(reason)}")
        stop(data, reason)

      {:stop, _, _} = stop ->
        stop
    end
  end

  defp handle_message(msg, data) do
    stop(data, {:unknown_message, msg})
  end

  defp send_reply(reply, %State{channel: chan, socket: socket} = data) do
    with {_, {:ok, encoded}} <- {:encode, Encoding.encode(reply)},
         {_, {:ok, new_chan, encrypted}} <- {:encrypt, Channel.encrypt(chan, encoded)},
         {:ok, new_socket} <- Transport.send(socket, encrypted) do
      {:ok, %State{data | channel: new_chan, socket: new_socket}}
    else
      {:encode, {:error, reason}} ->
        log_warn("Encoding failed: #{inspect(reason)}")
        throw(:failed_encode)

      {:encrypt, {:error, reason}} ->
        log_warn("Encrypt failed: #{inspect(reason)}")
        throw(:failed_encrypt)

      {:error, reason} ->
        throw(reason)

      other ->
        log_error("Invalid/unexpected result value in send_reply: #{inspect(other)}")
        throw(:fatal_error)
    end
  catch
    :throw, reason ->
      log_error("Error occurred while sending reply: #{inspect(reason)}")
      stop(data, reason)
  end

  defp stop(%State{socket: nil} = data, :closed) do
    {:stop, :shutdown, data}
  end

  defp stop(%State{socket: nil} = data, reason) do
    {:stop, reason, data}
  end

  defp stop(%State{socket: socket} = data, reason) do
    case Transport.close(socket) do
      {:ok, new_socket} ->
        {:stop, reason, %State{data | socket: new_socket}}

      {:error, :closed} when reason == :closed ->
        # Already closed
        {:stop, :shutdown, %State{data | socket: nil}}

      {:error, :closed} ->
        # Already closed
        {:stop, reason, %State{data | socket: nil}}

      {:error, err} ->
        log_warn("Failed to cleanly shutdown socket: #{inspect(err)}")
        {:stop, reason, %State{data | socket: nil}}
    end
  end

  defp log_debug(message) do
    Logger.debug(message)
  end

  defp log_warn(message) do
    Logger.debug(message)
  end

  defp log_error(message) do
    Logger.error(message)
  end
end
