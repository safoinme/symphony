defmodule SymphonyElixir.CircuitBreakerTest do
  use ExUnit.Case

  alias SymphonyElixir.CircuitBreaker

  setup do
    name = :"cb_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = CircuitBreaker.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    %{server: name}
  end

  describe "initial state" do
    test "starts closed", %{server: server} do
      assert :closed == CircuitBreaker.get_state(:test_provider, server)
    end

    test "check returns :ok when closed", %{server: server} do
      assert :ok == CircuitBreaker.check(:test_provider, server)
    end
  end

  describe "failure tracking" do
    test "stays closed below threshold", %{server: server} do
      for _ <- 1..4 do
        CircuitBreaker.record_failure(:provider_a, server)
      end

      assert :closed == CircuitBreaker.get_state(:provider_a, server)
      assert :ok == CircuitBreaker.check(:provider_a, server)
    end

    test "opens after reaching threshold", %{server: server} do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:provider_b, server)
      end

      assert :open == CircuitBreaker.get_state(:provider_b, server)
      assert {:error, :circuit_open} == CircuitBreaker.check(:provider_b, server)
    end
  end

  describe "recovery" do
    test "success resets to closed", %{server: server} do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:provider_c, server)
      end

      assert :open == CircuitBreaker.get_state(:provider_c, server)

      CircuitBreaker.record_success(:provider_c, server)
      assert :closed == CircuitBreaker.get_state(:provider_c, server)
      assert :ok == CircuitBreaker.check(:provider_c, server)
    end
  end

  describe "reset/2" do
    test "clears provider state", %{server: server} do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:provider_d, server)
      end

      assert :open == CircuitBreaker.get_state(:provider_d, server)

      CircuitBreaker.reset(:provider_d, server)
      assert :closed == CircuitBreaker.get_state(:provider_d, server)
    end
  end

  describe "isolation" do
    test "providers are independent", %{server: server} do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:provider_x, server)
      end

      assert :open == CircuitBreaker.get_state(:provider_x, server)
      assert :closed == CircuitBreaker.get_state(:provider_y, server)
    end
  end
end
