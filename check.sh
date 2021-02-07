#!/usr/bin/env bash

COINGECKO_API="https://api.coingecko.com/api/v3"
# IMPORTANT: check that this is the real ENS registry!
ENS_REGISTRY=0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e
# IMPORTANT: check that this is what MTC owns!
FUND_DEPLOYER_CONTRACT="0x9134C9975244b46692Ad9A7Da36DBa8734Ec6DA3"
# IMPORTANT: check that this is the real uniswap factory
UNISWAP_V2_FACTORY_ADDRESS=0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f
# IMPORTANT: check these tokens!
WETH_ADDRESS=0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
BNB_ADDRESS=0xb8c77482e45f1f44de1745f52c74426c631bdd52
COMP_ADDRESS=0xc00e94cb662c3520282e6f5717214004a7f26888
REPV2_ADDRESS=0x221657776846890989a759ba2973e427dff5c9bb

COMPTROLLER_LIB_CONTRACT=$(seth call $FUND_DEPLOYER_CONTRACT "getComptrollerLib()(address)")

namehash() {
  if [[ $# == 0 ]]; then
    seth --to-bytes32 0
  else
    seth keccak $(namehash "${@:2}")$(seth keccak "$1" | cut -c3-)
  fi
}

resolve_ens() {
  namehash=$(namehash "$@")
  resolver=$(seth call $ENS_REGISTRY "resolver(bytes32)(address)" "$namehash")
  res=$(seth call $resolver "addr(bytes32)(address)" "$namehash")
  echo ${res,,}
}

id_by_symbol () {
  # UNI for uniswap not unicorn
  if [[ ${1,,} == "uni" ]]; then echo "uniswap"; exit 0; fi
  id=$(curl -s $COINGECKO_API/coins/list | jq -r ".[] | select(.symbol==\"${1,,}\") | .id")
  if [[ -z $id ]]; then echo "symbol $1 not found in coingecko API!"; fi
  echo $id
}

contract_by_symbol () {
  if [[ $1 == "WETH" ]]; then
    echo $WETH_ADDRESS
  elif [[ $1 == "BNB" ]]; then
    echo $BNB_ADDRESS
  elif [[ $1 == "COMP" ]]; then
    echo $COMP_ADDRESS
  elif [[ $1 == "REPv2" ]]; then
    echo $REPV2_ADDRESS
  else
    id=$(id_by_symbol $1)
    contract=$(curl -s $COINGECKO_API/coins/$id | jq -r ".contract_address")
    echo ${contract,,}
  fi
}

get_uniswap_pair () {
  res=$(seth call $UNISWAP_V2_FACTORY_ADDRESS "getPair(address,address)(address)" $1 $2)
  echo ${res,,}
}

unwrap_symbol () {
  if [[ "$1" == "weth" || "$1" == "wbtc" ]]; then
    cut -c2- <<< "$1"
  elif [[ "$1" == "repv2" ]]; then
    echo "rep"
  else
    echo "$1"
  fi
}

warning () {
  echo "$(tput setaf 1)$@$(tput sgr 0)"
}

# locate the primitive price feed
readarray -t res < <(seth call $COMPTROLLER_LIB_CONTRACT "getLibRoutes()(address,address,address,address,address,address,address)")
PRIMITIVE_PRICE_FEED_CONTRACT=${res[5]}
VALUE_INTERPRETER_CONTRACT=${res[6]}
echo "Assuming fund deployer: $FUND_DEPLOYER_CONTRACT"
echo "Found ComptrollerLib: $COMPTROLLER_LIB_CONTRACT"
echo "Found primitive price feed: $PRIMITIVE_PRICE_FEED_CONTRACT"
echo "Found ValueInterpreter: $VALUE_INTERPRETER_CONTRACT"
AGGREGATED_DERIVATIVE_PRICE_FEED_CONTRACT=$(seth call $VALUE_INTERPRETER_CONTRACT "getAggregatedDerivativePriceFeed()(address)")
echo "Found AggregatedDerivativePriceFeed: $AGGREGATED_DERIVATIVE_PRICE_FEED_CONTRACT"

while IFS=, read -r name symbol decimals address assetType derivType uniPair x chainlinkProxy x
do
  symbol="${symbol//\"}"
  address="${address//\"}"
  address="${address,,}"
  assetType="${assetType//\"}"
  # skip column line
  if [[ "$symbol" == "Symbol" ]]; then continue; fi
  echo "Checking $symbol..."
  # skip Uniswap LP shares
  if [[ "$symbol" == "UNI-V2" || "$name" == "\"Uniswap V2\"" ]]; then
    IFS="-" read a b <<< "${uniPair//\"}"
    canonical_pair=$(get_uniswap_pair $(contract_by_symbol $a) $(contract_by_symbol $b))
    if [[ "$address" != "$canonical_pair" ]]; then
      warning "Purported uniswap pair $uniPair doesn't match canonical address."
      echo "canonical: $canonical_pair"
      echo "actual: $address"
    else
      echo "${uniPair//\"} matches canonical pair."
    fi
    pair_price_feed=$(seth call $AGGREGATED_DERIVATIVE_PRICE_FEED_CONTRACT "getPriceFeedForDerivative(address)(address)" $address)
    pair_primitive_feed=$(seth call $pair_price_feed "getPrimitivePriceFeed()(address)")
    if [[ "$pair_primitive_feed" != $PRIMITIVE_PRICE_FEED_CONTRACT ]]; then
      warning "Primitive price feed on pair ${uniPair,,} DOESN'T match!"
      echo "found: $pair_primitive_feed"
    else
      echo "Primitive price feed matches."
    fi
    continue
  fi
  if [[ -z "$address" ]]; then
    echo "No contract address for token $symbol, skipping..."
  fi
  coingecko_address=$(contract_by_symbol $symbol)
  if [[ "$coingecko_address" != "$address" ]]; then
    warning "Contract address for $symbol does NOT match coingecko!"
    echo "coingecko: $coingecko_address"
    echo "address: $address"
  fi
  if [[ "$assetType" == "Primitive" ]]; then
    readarray -t res < <(seth call $PRIMITIVE_PRICE_FEED_CONTRACT "getAggregatorInfoForPrimitive(address)(address,uint8)" $address)
    feed="${res[0],,}"
    isEth="${res[1]}"
    pair="$(unwrap_symbol ${symbol,,})-$([[ $isEth == 0 ]] && echo eth || echo usd)"
    official_feed=$(resolve_ens $pair data eth)
    if [[ "$feed" != "$official_feed" ]]; then
      warning "Feed proxy for $symbol does NOT match chainlink ENS!"
      echo "$pair.data.eth: $official_feed"
      echo "feed: $feed"
    else
      echo "$pair.data.eth agrees."
    fi
  fi
done < $1
