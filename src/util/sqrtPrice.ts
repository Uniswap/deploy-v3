import { BigNumber } from 'bignumber.js'

export function encodePriceSqrt(reserve1: any, reserve0: any) {
  BigNumber.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 })

  return new BigNumber(reserve1.toString())
    .div(reserve0.toString())
    .sqrt()
    .multipliedBy(new BigNumber(2).pow(96))
    .integerValue(3)
    .toString()
}
