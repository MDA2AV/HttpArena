defmodule PhoenixBanditWeb.EchoWebSocket do
  @behaviour WebSock

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({message, [opcode: :text]}, state) do
    {:reply, :ok, {:text, message}, state}
  end

  def handle_in({message, [opcode: :binary]}, state) do
    {:reply, :ok, {:binary, message}, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
