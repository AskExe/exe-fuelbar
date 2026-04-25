import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../src/config.js', () => ({
  readConfig: vi.fn().mockResolvedValue({}),
}))

import {
  isValidCurrencyCode,
  formatCost,
  convertCost,
  getCurrency,
  getCostColumnHeader,
  switchCurrency,
} from '../src/currency.js'

beforeEach(async () => {
  // Reset to USD before each test
  await switchCurrency('USD')
})

describe('isValidCurrencyCode', () => {
  it.each(['USD', 'EUR', 'GBP', 'JPY', 'CAD', 'AUD', 'CHF'])(
    'accepts valid ISO 4217 code %s',
    (code) => {
      expect(isValidCurrencyCode(code)).toBe(true)
    },
  )

  it.each(['123', '', 'ABCDE', 'ZZ', 'notacurrency'])(
    'rejects invalid code %s',
    (code) => {
      expect(isValidCurrencyCode(code)).toBe(false)
    },
  )
})

describe('formatCost', () => {
  describe('USD defaults', () => {
    it('formats zero as $0.0000', () => {
      expect(formatCost(0)).toBe('$0.0000')
    })

    it('formats $1.50 with 2 decimal places', () => {
      expect(formatCost(1.5)).toBe('$1.50')
    })

    it('formats $100 with 2 decimal places', () => {
      expect(formatCost(100)).toBe('$100.00')
    })

    it('formats $0.005 with 4 decimal places (below $0.01 threshold)', () => {
      expect(formatCost(0.005)).toBe('$0.0050')
    })

    it('formats $0.0001 with 4 decimal places', () => {
      expect(formatCost(0.0001)).toBe('$0.0001')
    })

    it('formats $0.50 with 3 decimal places (mid-range)', () => {
      expect(formatCost(0.5)).toBe('$0.500')
    })
  })

  describe('precision tiers', () => {
    it('uses 2 digits for amounts >= $1', () => {
      expect(formatCost(5.678)).toBe('$5.68')
    })

    it('uses 3 digits for amounts >= $0.01 and < $1', () => {
      expect(formatCost(0.01)).toBe('$0.010')
      expect(formatCost(0.999)).toBe('$0.999')
    })

    it('uses 4 digits for amounts < $0.01', () => {
      expect(formatCost(0.009)).toBe('$0.0090')
      expect(formatCost(0.0005)).toBe('$0.0005')
    })
  })
})

describe('convertCost', () => {
  it('returns value rounded to 2 digits for USD (rate=1)', () => {
    expect(convertCost(1.555)).toBe(1.56)
    expect(convertCost(0.001)).toBe(0)
    expect(convertCost(10)).toBe(10)
  })

  it('returns exact value for whole numbers', () => {
    expect(convertCost(100)).toBe(100)
  })
})

describe('getCurrency', () => {
  it('returns USD state by default', () => {
    const state = getCurrency()
    expect(state.code).toBe('USD')
    expect(state.rate).toBe(1)
    expect(state.symbol).toBe('$')
  })
})

describe('getCostColumnHeader', () => {
  it('returns "Cost (USD)" by default', () => {
    expect(getCostColumnHeader()).toBe('Cost (USD)')
  })
})

describe('switchCurrency', () => {
  afterEach(async () => {
    await switchCurrency('USD')
  })

  it('resets to USD state', async () => {
    await switchCurrency('USD')
    const state = getCurrency()
    expect(state.code).toBe('USD')
    expect(state.rate).toBe(1)
    expect(state.symbol).toBe('$')
  })

  it('updates cost column header after switch to USD', async () => {
    await switchCurrency('USD')
    expect(getCostColumnHeader()).toBe('Cost (USD)')
  })
})
