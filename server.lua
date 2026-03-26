local config = require 'config'

if not config then return end

if config.versionCheck then lib.versionCheck('overextended/ox_fuel') end

local ox_inventory = exports.ox_inventory

local function setFuelState(netId, fuel)
	local vehicle = NetworkGetEntityFromNetworkId(netId)

	if vehicle == 0 or GetEntityType(vehicle) ~= 2 then
		return
	end

	local state = Entity(vehicle)?.state
	fuel = math.clamp(fuel, 0, 100)

	state:set('fuel', fuel, true)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Core Business helpers
-----------------------------------------------------------------------------------------------------------------------------------------

local function getPlayerCoords(source)
	local ped = GetPlayerPed(source)
	return ped and GetEntityCoords(ped)
end

local function coreBusinessRemoveFuel(source, fuelPercent)
	if not config.coreBusiness or not config.coreBusiness.enabled then return true end

	local coords = getPlayerCoords(source)
	if not coords then return true end

	local fuelItem = config.coreBusiness.fuelItem
	local litersPerItem = config.coreBusiness.litersPerFuelItem or 1
	local itemsNeeded = math.max(1, math.ceil(fuelPercent / litersPerItem))

	local itemCount = exports['core_business']:closestPropertyItemCount(coords, fuelItem)
	if itemCount == 1000.0 then return true end

	local removed = exports['core_business']:closestPropertyRemoveItem(coords, fuelItem, itemsNeeded)
	return removed
end

local function coreBusinessRegisterSale(source, price, logMsg)
	if not config.coreBusiness or not config.coreBusiness.enabled or not config.coreBusiness.registerSales then return end

	local coords = getPlayerCoords(source)
	if not coords then return end

	exports['core_business']:closestPropertyRegisterSale(coords, price, logMsg or "Fuel sale")
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Payment
-----------------------------------------------------------------------------------------------------------------------------------------

---@param playerId number
---@param price number
---@return boolean?
local function defaultPaymentMethod(playerId, price)
	local success = ox_inventory:RemoveItem(playerId, 'money', price)

	if success then return true end

	local money = ox_inventory:GetItemCount(source, 'money')

	TriggerClientEvent('ox_lib:notify', source, {
		type = 'error',
		description = locale('not_enough_money', price - money)
	})
end

local payMoney = defaultPaymentMethod

exports('setPaymentMethod', function(fn)
	payMoney = fn or defaultPaymentMethod
end)

RegisterNetEvent('ox_fuel:pay', function(price, fuel, netid)
	assert(type(price) == 'number', ('Price expected a number, received %s'):format(type(price)))
	local src = source

	local fuelPercent = math.floor(fuel)

	local useCorePay = config.coreBusiness and config.coreBusiness.enabled and config.coreBusiness.useCorePay
	local coords = useCorePay and getPlayerCoords(src)
	local businessId = coords and exports['core_business']:closestPropertyGetBusinessId(coords)

	if useCorePay and businessId then
		-- CorePay path: verify stock, pay first, remove stock on success
		local fuelItem = config.coreBusiness.fuelItem
		local litersPerItem = config.coreBusiness.litersPerFuelItem or 1
		local itemsNeeded = math.max(1, math.ceil(fuelPercent / litersPerItem))
		local itemCount = exports['core_business']:closestPropertyItemCount(coords, fuelItem)
		if itemCount ~= 1000.0 and itemCount < itemsNeeded then
			TriggerClientEvent('ox_lib:notify', src, {
				type = 'error',
				description = locale('not_enough_stock') or 'Not enough fuel in stock'
			})
			return
		end

		exports['core_business']:requestCorePay(src, businessId, price, string.format("Fuel: %d%%", fuelPercent), function(success)
			if success then
				coreBusinessRemoveFuel(src, fuelPercent)
				setFuelState(netid, fuelPercent)
				TriggerClientEvent('ox_lib:notify', src, {
					type = 'success',
					description = locale('fuel_success', fuelPercent, price)
				})
			else
				local vehicle = NetworkGetEntityFromNetworkId(netid)
				if vehicle ~= 0 and GetEntityType(vehicle) == 2 then
					local currentFuel = Entity(vehicle)?.state?.fuel
					if currentFuel then
						setFuelState(netid, currentFuel)
					end
				end
			end
		end)
	else
		if not coreBusinessRemoveFuel(src, fuelPercent) then
			local vehicle = NetworkGetEntityFromNetworkId(netid)
			if vehicle ~= 0 and GetEntityType(vehicle) == 2 then
				local currentFuel = Entity(vehicle)?.state?.fuel
				if currentFuel then
					setFuelState(netid, currentFuel)
				end
			end

			TriggerClientEvent('ox_lib:notify', src, {
				type = 'error',
				description = locale('not_enough_stock') or 'Not enough fuel in stock'
			})
			return
		end

		if not payMoney(src, price) then return end

		setFuelState(netid, fuelPercent)

		coreBusinessRegisterSale(src, price, string.format("Fuel sale: %d%% for $%d", fuelPercent, price))

		TriggerClientEvent('ox_lib:notify', src, {
			type = 'success',
			description = locale('fuel_success', fuelPercent, price)
		})
	end
end)

RegisterNetEvent('ox_fuel:fuelCan', function(hasCan, price)
	local source = source
	if hasCan then
		local item = ox_inventory:GetCurrentWeapon(source)

		if not item or item.name ~= 'WEAPON_PETROLCAN' or not payMoney(source, price) then return end

		item.metadata.durability = 100
		item.metadata.ammo = 100

		ox_inventory:SetMetadata(source, item.slot, item.metadata)

		coreBusinessRegisterSale(source, price, "Petrol can refill")

		TriggerClientEvent('ox_lib:notify', source, {
			type = 'success',
			description = locale('petrolcan_refill', price)
		})
	else
		if not ox_inventory:CanCarryItem(source, 'WEAPON_PETROLCAN', 1) then
			return TriggerClientEvent('ox_lib:notify', source, {
				type = 'error',
				description = locale('petrolcan_cannot_carry')
			})
		end

		if not payMoney(source, price) then return end

		ox_inventory:AddItem(source, 'WEAPON_PETROLCAN', 1)

		coreBusinessRegisterSale(source, price, "Petrol can purchase")

		TriggerClientEvent('ox_lib:notify', source, {
			type = 'success',
			description = locale('petrolcan_buy', price)
		})
	end
end)

RegisterNetEvent('ox_fuel:updateFuelCan', function(durability, netid, fuel)
	local source = source
	local item = ox_inventory:GetCurrentWeapon(source)

	if item and durability > 0 then
		durability = math.floor(item.metadata.durability - durability)
		item.metadata.durability = durability
		item.metadata.ammo = durability

		ox_inventory:SetMetadata(source, item.slot, item.metadata)
		setFuelState(netid, fuel)
	end

	-- player is sus?
end)
