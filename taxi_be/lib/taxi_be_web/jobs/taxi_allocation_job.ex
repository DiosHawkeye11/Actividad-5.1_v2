defmodule TaxiBeWeb.TaxiAllocationJob do
  alias Mix.ProjectStack
  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request, taxis: select_candidate_taxis(request), timeout_ref: nil, estimated_arrival_time: nil, accepted_taxi: nil, rejected_taxis: [], count: 0}}
  end

  def handle_info(:step1, %{request: request, taxis: taxis} = state) do

    task = Task.async(fn ->
      compute_ride_fare(request)
      |> notify_customer_ride_fare()
    end)

    Task.await(task)

    Enum.map(taxis, fn taxi ->
      %{
        "pickup_address" => pickup_address,
        "dropoff_address" => dropoff_address,
        "booking_id" => booking_id
      } = request

      TaxiBeWeb.Endpoint.broadcast(
        "driver:" <> taxi.nickname,
        "booking_request",
        %{
          msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
          bookingId: booking_id
        }
      )
    end)

    timeout_ref = Process.send_after(self(), :timeout1, 5000)
    {:noreply, %{state | timeout_ref: timeout_ref}}
  end

  def handle_info(:timeout1, %{request: request} = state) do
    %{"username" => username} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> username, "booking_request", %{msg: "Ningún taxi aceptó tu solicitud. Intenta nuevamente."})
    {:stop, :normal, state}
  end

  def handle_cast({:process_accept, driver_username}, %{request: request, timeout_ref: timeout_ref} = state) do
    Process.cancel_timer(timeout_ref)
    %{
      "pickup_address" => pickup_address,
      "username" => username
    } = request

    IO.inspect(driver_username)
    taxi = select_candidate_taxis(request) |> Enum.filter(fn taxi -> taxi.nickname == driver_username end) |> hd
    coords = {:ok, [taxi.longitude, taxi.latitude]}
    estimated_arrival_time = calculate_estimated_arrival_time(pickup_address, coords)

    TaxiBeWeb.Endpoint.broadcast("customer:" <> username, "booking_request", %{msg: "Tu taxi está en camino con el conductor #{driver_username}, llega en #{estimated_arrival_time} minutos"})
    {:noreply, %{state |estimated_arrival_time: estimated_arrival_time, accepted_taxi: driver_username}}
  end

  def handle_info({:tick, count}, state) do
    Process.send_after(self(), {:tick, count + 1}, 1000)
    {:noreply, %{state | count: count}}
  end

  def handle_cast({:process_cancel, username}, %{estimated_arrival_time: est_arrival_time, accepted_taxi: accepted_taxi, count: count} = state) do

    if est_arrival_time == nil do
      TaxiBeWeb.Endpoint.broadcast("customer:" <> username, "booking_request", %{msg: "Viaje cancelado."})
      TaxiBeWeb.Endpoint.broadcast("driver:" <> accepted_taxi, "booking_request", %{msg: "El usuario canceló el viaje"})
    else
      Process.send_after(self(), {:tick, state.count + 1}, 1000)
      arrival_margin = est_arrival_time * 60 - count
      IO.inspect(arrival_margin)
      if arrival_margin <= 180 do
        TaxiBeWeb.Endpoint.broadcast("customer:" <> username, "booking_request", %{msg: "Viaje cancelado. Se aplica un cargo de $20."})
        TaxiBeWeb.Endpoint.broadcast("driver:" <> accepted_taxi, "booking_request", %{msg: "El usuario canceló el viaje"})

      else
        TaxiBeWeb.Endpoint.broadcast("customer:" <> username, "booking_request", %{msg: "Viaje cancelado."})
        TaxiBeWeb.Endpoint.broadcast("driver:" <> accepted_taxi, "booking_request", %{msg: "El usuario canceló el viaje"})
      end
      {:noreply, state}
    end
  end

  def handle_info({:tick, count}, state) do
    Process.send_after(self(), {:tick, count + 1}, 1000)
    {:noreply, %{state | count: count}}
  end

  def handle_cast({:process_notify_arrival, username}, state) do
    TaxiBeWeb.Endpoint.broadcast("customer:" <> username, "booking_request", %{msg: "Ya llegue "})
    {:noreply, state}
  end

  def handle_cast({:process_reject, driver_username}, %{rejected_taxis: rejected_taxis, taxis: taxis} = state) do
    updated_rejected_taxis = [driver_username | rejected_taxis]

    if length(updated_rejected_taxis) == length(taxis) do
      self() |> send(:timeout1)
    end

    {:noreply, %{state | rejected_taxis: updated_rejected_taxis}}
  end

  def compute_ride_fare(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address
    } = request

    coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, Float.ceil(distance / 300)}
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Ride fare: #{fare}"})
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "Yoda", latitude: 19.0319783, longitude: -98.2349368},  # Angelopolis
      %{nickname: "Anakin", latitude: 19.0061167, longitude: -98.2697737},  # Arcangeles
      %{nickname: "Obi-Wan", latitude: 19.0092933, longitude: -98.2473716}   # Paseo Destino
    ]
  end

  def calculate_estimated_arrival_time(pickup_address, coords) do
    coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    {_distance, duration} = TaxiBeWeb.Geolocator.distance_and_duration(coords, coord1)
    Float.ceil(duration / 60)
  end

end
