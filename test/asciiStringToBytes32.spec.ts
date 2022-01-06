import { expect } from 'chai'
import { asciiStringToBytes32 } from '../src/util/asciiStringToBytes32'

describe('#asciiStringToBytes32', () => {
  it('works for ETH', async () => {
    expect(asciiStringToBytes32('ETH')).to.eq('0x4554480000000000000000000000000000000000000000000000000000000000')
  })
  it('works for MATIC', async () => {
    expect(asciiStringToBytes32('MATIC')).to.eq('0x4d41544943000000000000000000000000000000000000000000000000000000')
  })
  it('throws for invalid string', async () => {
    expect(() => asciiStringToBytes32('🤌')).to.throw('Invalid label, must be less than 32 characters')
  })
  it('throws for string too long', async () => {
    expect(() => asciiStringToBytes32(''.padEnd(33, '0'))).to.throw('Invalid label, must be less than 32 characters')
  })
})
