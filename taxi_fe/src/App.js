import React from 'react';
import './App.css';

import Customer from './components/Customer';
import Driver from './components/Driver';

function App() {
  return (
    <div className="App">
      <Customer username="Alex"/>
      <Driver username="Yoda"/>
      <Driver username="Anakin"/>
      <Driver username="Obi-Wan"/>
    </div>
  );
}

export default App;
