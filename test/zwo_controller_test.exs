defmodule ZwoControllerTest do
  use ExUnit.Case
  doctest ZwoController

  alias ZwoController.{Coordinates, Protocol}

  describe "Coordinates" do
    test "ra_to_hms converts decimal hours to HMS" do
      assert %{hours: 6, minutes: 30, seconds: 0.0} = Coordinates.ra_to_hms(6.5)
      assert %{hours: 0, minutes: 0, seconds: 0.0} = Coordinates.ra_to_hms(0)
      assert %{hours: 23, minutes: 59, seconds: _} = Coordinates.ra_to_hms(23.999)
    end

    test "dec_to_dms converts decimal degrees to DMS" do
      assert %{degrees: 45, minutes: 30, seconds: 0.0} = Coordinates.dec_to_dms(45.5)
      assert %{degrees: -23, minutes: 30, seconds: 0.0} = Coordinates.dec_to_dms(-23.5)
      assert %{degrees: 0, minutes: 30, seconds: 0.0} = Coordinates.dec_to_dms(0.5)
    end

    test "hms_to_ra converts HMS to decimal hours" do
      assert 6.5 == Coordinates.hms_to_ra(6, 30, 0)
      assert 12.5 == Coordinates.hms_to_ra(12, 30, 0)
    end

    test "dms_to_dec converts DMS to decimal degrees" do
      assert 45.5 == Coordinates.dms_to_dec(45, 30, 0)
      assert -45.5 == Coordinates.dms_to_dec(-45, 30, 0)
    end

    test "normalize_ra wraps to 0-24 range" do
      assert 0.0 == Coordinates.normalize_ra(24.0)
      assert 1.0 == Coordinates.normalize_ra(25.0)
      assert 23.0 == Coordinates.normalize_ra(-1.0)
    end

    test "normalize_dec clamps to -90 to 90" do
      assert 90.0 == Coordinates.normalize_dec(91.0)
      assert -90.0 == Coordinates.normalize_dec(-91.0)
      assert 45.0 == Coordinates.normalize_dec(45.0)
    end
  end

  describe "Protocol" do
    test "generates correct getter commands" do
      assert ":GR#" == Protocol.get_ra()
      assert ":GD#" == Protocol.get_dec()
      assert ":GV#" == Protocol.get_version()
      assert ":GAT#" == Protocol.get_tracking_status()
    end

    test "generates correct target RA command" do
      assert ":Sr12:30:00#" == Protocol.set_target_ra(12.5)
      assert ":Sr00:00:00#" == Protocol.set_target_ra(0)
      assert ":Sr06:15:00#" == Protocol.set_target_ra(6.25)
    end

    test "generates correct target DEC command" do
      assert ":Sd+45*30:00#" == Protocol.set_target_dec(45.5)
      assert ":Sd-23*30:00#" == Protocol.set_target_dec(-23.5)
      assert ":Sd+00*30:00#" == Protocol.set_target_dec(0.5)
    end

    test "generates correct motion commands" do
      assert ":Mn#" == Protocol.move_north()
      assert ":Ms#" == Protocol.move_south()
      assert ":Me#" == Protocol.move_east()
      assert ":Mw#" == Protocol.move_west()
    end

    test "generates correct guide pulse commands" do
      assert ":Mgn0500#" == Protocol.guide_pulse_north(500)
      assert ":Mgs1000#" == Protocol.guide_pulse_south(1000)
    end

    test "generates correct tracking commands" do
      assert ":Te#" == Protocol.tracking_on()
      assert ":Td#" == Protocol.tracking_off()
      assert ":TQ#" == Protocol.tracking_sidereal()
    end

    test "parses RA response" do
      assert {:ok, {12, 30, 45}} == Protocol.parse_ra("12:30:45#")
      assert {:ok, {0, 0, 0}} == Protocol.parse_ra("00:00:00#")
    end

    test "parses DEC response" do
      assert {:ok, {45, 30, 0}} == Protocol.parse_dec("+45*30:00#")
      assert {:ok, {-23, 30, 0}} == Protocol.parse_dec("-23*30:00#")
    end

    test "parses tracking status" do
      assert {:ok, true} == Protocol.parse_tracking_status("1#")
      assert {:ok, false} == Protocol.parse_tracking_status("0#")
    end

    test "parses goto response" do
      assert :ok == Protocol.parse_goto_response("0#")
      assert {:error, :object_below_horizon} == Protocol.parse_goto_response("1#")
    end
  end

  describe "Mock mount" do
    setup do
      {:ok, mount} = ZwoController.start_mock()
      %{mount: mount}
    end

    test "returns position", %{mount: mount} do
      {:ok, pos} = ZwoController.position(mount)
      assert is_float(pos.ra)
      assert is_float(pos.dec)
    end

    test "accepts goto command", %{mount: mount} do
      assert :ok == ZwoController.goto(mount, 12.5, 45.0)
    end

    test "accepts tracking commands", %{mount: mount} do
      assert :ok == ZwoController.track(mount, :sidereal)
      assert {:ok, true} == ZwoController.tracking?(mount)
      assert :ok == ZwoController.track_off(mount)
      assert {:ok, false} == ZwoController.tracking?(mount)
    end

    test "accepts motion commands", %{mount: mount} do
      assert :ok == ZwoController.move(mount, :north)
      assert :ok == ZwoController.stop_motion(mount, :north)
      assert :ok == ZwoController.stop(mount)
    end

    test "accepts guide pulses", %{mount: mount} do
      assert :ok == ZwoController.guide(mount, :north, 500)
      assert :ok == ZwoController.guide(mount, :south, 500)
    end

    test "returns mount info", %{mount: mount} do
      {:ok, info} = ZwoController.info(mount)
      assert info.model =~ "AM5"
      assert is_binary(info.version)
    end
  end
end
