import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('shop_token') || '')
  const username = ref(localStorage.getItem('shop_username') || '')
  const activeShopId = ref(localStorage.getItem('shop_active_id') || '')
  const activeShopName = ref(localStorage.getItem('shop_active_name') || '')

  const scopeVersion = ref(0)
  const activeShopRole = ref(localStorage.getItem('shop_active_role') || '')
  const clearShop = () => {
    scopeVersion.value++
    activeShopId.value = ''; activeShopName.value = ''; activeShopRole.value = ''
    for (const key of ['shop_active_id', 'shop_active_name', 'shop_active_role']) localStorage.removeItem(key)
  }

  const setLoginInfo = (userToken: string, name: string) => {
    clearShop()
    token.value = userToken
    username.value = name
    localStorage.setItem('shop_token', userToken)
    localStorage.setItem('shop_username', name)
  }

  const setActiveShop = (shopId: string, shopName: string, role = '') => {
    scopeVersion.value++
    activeShopRole.value = role
    localStorage.setItem('shop_active_role', role)
    activeShopId.value = shopId
    activeShopName.value = shopName
    localStorage.setItem('shop_active_id', shopId)
    localStorage.setItem('shop_active_name', shopName)
  }

  const logout = () => {
    clearShop()
    token.value = ''
    username.value = ''
    activeShopId.value = ''
    activeShopName.value = ''
    localStorage.removeItem('shop_token')
    localStorage.removeItem('shop_username')
    localStorage.removeItem('shop_active_id')
    localStorage.removeItem('shop_active_name')
  }

  return {
    token,
    username,
    activeShopId,
    activeShopName,
    activeShopRole,
    scopeVersion,
    clearShop,
    setLoginInfo,
    setActiveShop,
    logout
  }
})
