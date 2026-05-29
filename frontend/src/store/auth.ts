import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('shop_token') || '')
  const username = ref(localStorage.getItem('shop_username') || '')
  const activeShopId = ref(localStorage.getItem('shop_active_id') || '')
  const activeShopName = ref(localStorage.getItem('shop_active_name') || '')

  const setLoginInfo = (userToken: string, name: string) => {
    token.value = userToken
    username.value = name
    localStorage.setItem('shop_token', userToken)
    localStorage.setItem('shop_username', name)
  }

  const setActiveShop = (shopId: string, shopName: string) => {
    activeShopId.value = shopId
    activeShopName.value = shopName
    localStorage.setItem('shop_active_id', shopId)
    localStorage.setItem('shop_active_name', shopName)
  }

  const logout = () => {
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
    setLoginInfo,
    setActiveShop,
    logout
  }
})
